use crate::model;
use lockedin_flow_core::{MAX_RECORDING_SECONDS, MAX_TRANSCRIPT_BYTES, SAMPLE_RATE};
use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};
use zeroize::Zeroizing;

pub struct SpeechEngine {
    context: WhisperContext,
}

pub trait Recognizer {
    fn recognize(&self, samples: &[f32]) -> Result<String, &'static str>;
}

impl Recognizer for SpeechEngine {
    fn recognize(&self, samples: &[f32]) -> Result<String, &'static str> {
        self.transcribe(samples)
    }
}

impl SpeechEngine {
    pub fn load(path: &Path) -> Result<Self, &'static str> {
        whisper_rs::install_logging_hooks();
        let bytes = model::read_verified(path)?;
        let mut options = WhisperContextParameters::default();
        options.use_gpu(false); // CPU baseline: no vendor GPU runtime or external service.
        let context =
            WhisperContext::new_from_buffer_with_params(&bytes, options).map_err(|_| {
                "The speech engine could not load the verified model. Check available memory."
            })?;
        Ok(Self { context })
    }

    pub fn transcribe(&self, samples: &[f32]) -> Result<String, &'static str> {
        if samples.len() > MAX_RECORDING_SECONDS * SAMPLE_RATE
            || samples.iter().any(|v| !v.is_finite())
        {
            return Err("The recording is not valid for local transcription.");
        }
        if samples.len() < SAMPLE_RATE / 4 {
            return Err("The recording was too short. Please try again.");
        }
        let rms = (samples.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / samples.len() as f64)
            .sqrt();
        if rms < 0.0001 {
            return Err("No audible speech was captured. Check your selected microphone.");
        }
        let mut state = self
            .context
            .create_state()
            .map_err(|_| "The speech engine could not prepare this recording.")?;
        let mut parameters = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        let threads = std::thread::available_parallelism()
            .map(|n| n.get().min(8))
            .unwrap_or(2);
        parameters.set_n_threads(threads as i32);
        parameters.set_language(Some("en"));
        parameters.set_translate(false);
        parameters.set_no_context(true);
        parameters.set_no_timestamps(true);
        parameters.set_print_special(false);
        parameters.set_print_progress(false);
        parameters.set_print_realtime(false);
        parameters.set_print_timestamps(false);
        parameters.set_suppress_blank(true);
        parameters.set_temperature(0.0);
        parameters.set_temperature_inc(0.0);
        state.full(parameters, samples).map_err(|_| "Local transcription failed. Your recording is available for retry until you discard it or close the app.")?;
        let mut text = Zeroizing::new(String::new());
        for segment in state.as_iter() {
            let part = segment.to_str().map_err(|_| {
                "The speech engine returned invalid text. You can retry this recording."
            })?;
            if text.len().saturating_add(part.len()) > MAX_TRANSCRIPT_BYTES {
                return Err("The transcription exceeded the safety limit.");
            }
            text.push_str(part);
        }
        Ok(text.trim().to_string())
    }
}
