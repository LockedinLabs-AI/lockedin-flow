use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    Sample,
};
use lockedin_flow_core::{
    audio::{CaptureBuffer, CaptureProgress},
    SAMPLE_RATE,
};
use rubato::{
    audioadapter::Adapter, audioadapter_buffers::direct::InterleavedSlice, Fft, FixedSync,
    Resampler,
};
use std::{
    sync::{Arc, Mutex},
    time::Instant,
};
use zeroize::Zeroizing;

pub struct Capture {
    stream: Option<cpal::Stream>,
    buffer: Arc<Mutex<CaptureBuffer>>,
    rate: u32,
    started: Instant,
    progress: CaptureProgress,
}

pub struct Captured {
    pub samples: Zeroizing<Vec<f32>>,
    pub sample_rate: u32,
    pub interrupted: bool,
    pub limit_reached: bool,
}

#[derive(Clone, Copy)]
pub struct CaptureStatus {
    pub seconds: usize,
    pub peak: f32,
    pub stopped: bool,
}

impl Capture {
    pub fn start() -> Result<Self, &'static str> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No microphone is available. Connect one and try again.")?;
        let config = device.default_input_config().map_err(|_| "The microphone is unavailable. Check microphone privacy settings and whether another app has exclusive access.")?;
        let rate = config.sample_rate().0;
        let buffer = Arc::new(Mutex::new(CaptureBuffer::new(rate)?));
        let stream_config = config.config();
        let stream = match config.sample_format() {
            cpal::SampleFormat::I8 => build::<i8>(&device, &stream_config, &buffer),
            cpal::SampleFormat::I16 => build::<i16>(&device, &stream_config, &buffer),
            cpal::SampleFormat::I32 => build::<i32>(&device, &stream_config, &buffer),
            cpal::SampleFormat::I64 => build::<i64>(&device, &stream_config, &buffer),
            cpal::SampleFormat::U8 => build::<u8>(&device, &stream_config, &buffer),
            cpal::SampleFormat::U16 => build::<u16>(&device, &stream_config, &buffer),
            cpal::SampleFormat::U32 => build::<u32>(&device, &stream_config, &buffer),
            cpal::SampleFormat::U64 => build::<u64>(&device, &stream_config, &buffer),
            cpal::SampleFormat::F32 => build::<f32>(&device, &stream_config, &buffer),
            cpal::SampleFormat::F64 => build::<f64>(&device, &stream_config, &buffer),
            _ => Err("This microphone format is not supported. Select another input device."),
        }?;
        stream
            .play()
            .map_err(|_| "The microphone could not start. Check microphone privacy settings.")?;
        Ok(Self {
            stream: Some(stream),
            buffer,
            rate,
            started: Instant::now(),
            progress: CaptureProgress::default(),
        })
    }

    pub fn status(&mut self) -> CaptureStatus {
        match self.buffer.lock() {
            Ok(mut buffer) => {
                if !buffer.full && self.progress.stalled(buffer.len(), self.started.elapsed()) {
                    buffer.interrupted = true;
                }
                CaptureStatus {
                    seconds: buffer.len() / self.rate as usize,
                    peak: buffer.peak,
                    stopped: buffer.full || buffer.interrupted,
                }
            }
            Err(_) => CaptureStatus {
                seconds: 0,
                peak: 0.0,
                stopped: true,
            },
        }
    }

    pub fn stop(mut self) -> Result<Captured, &'static str> {
        // Drop the stream before taking its samples so no late callback can race the conversion.
        self.stream.take();
        let mut buffer = self
            .buffer
            .lock()
            .map_err(|_| "Microphone capture state is unavailable.")?;
        let result = Captured {
            // Keep source-rate audio until recognition succeeds, including conversion failures.
            samples: Zeroizing::new(buffer.take()),
            sample_rate: self.rate,
            interrupted: buffer.interrupted,
            limit_reached: buffer.full,
        };
        Ok(result)
    }
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    buffer: &Arc<Mutex<CaptureBuffer>>,
) -> Result<cpal::Stream, &'static str>
where
    T: cpal::SizedSample + Copy,
    f32: cpal::FromSample<T>,
{
    let data_buffer = Arc::clone(buffer);
    let error_buffer = Arc::clone(buffer);
    let channels = config.channels as usize;
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                if let Ok(mut buffer) = data_buffer.lock() {
                    buffer.push_interleaved(data, channels, f32::from_sample);
                }
            },
            move |_| {
                // No device names, raw errors, or captured content in logs.
                if let Ok(mut buffer) = error_buffer.lock() {
                    buffer.interrupted = true;
                }
            },
            None,
        )
        .map_err(|_| {
            "The microphone could not be opened. Check input settings and exclusive access."
        })
}

pub fn resample(input: &[f32], rate: u32) -> Result<Vec<f32>, &'static str> {
    if !(8_000..=192_000).contains(&rate) || input.iter().any(|v| !v.is_finite()) {
        return Err("Invalid audio input.");
    }
    if input.is_empty() {
        return Ok(Vec::new());
    }
    if rate as usize == SAMPLE_RATE {
        return Ok(input.to_vec());
    }
    let adapter =
        InterleavedSlice::new(input, 1, input.len()).map_err(|_| "Audio conversion failed.")?;
    let mut resampler = Fft::<f32>::new(rate as usize, SAMPLE_RATE, 1024, 1, FixedSync::Both)
        .map_err(|_| "Audio conversion failed.")?;
    let output = resampler
        .process_all(&adapter, input.len(), None)
        .map_err(|_| "Audio conversion failed.")?;
    (0..output.frames())
        .map(|frame| {
            output
                .read_sample(0, frame)
                .ok_or("Audio conversion failed.")
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn forty_eight_khz_is_resampled_to_sixteen_khz() {
        let input: Vec<f32> = (0..48_000)
            .map(|i| (i as f32 * std::f32::consts::TAU * 440.0 / 48_000.0).sin() * 0.3)
            .collect();
        let output = resample(&input, 48_000).unwrap();
        assert_eq!(output.len(), 16_000);
        assert!(output.iter().all(|v| v.is_finite()));
        assert!(output.iter().any(|v| v.abs() > 0.2));
    }
    #[test]
    fn invalid_empty_and_native_rate_inputs_are_handled() {
        assert!(resample(&[f32::INFINITY], 16_000).is_err());
        assert!(resample(&[0.0], 0).is_err());
        assert_eq!(resample(&[], 48_000).unwrap(), []);
        assert_eq!(resample(&[0.1, -0.2], 16_000).unwrap(), [0.1, -0.2]);
    }
}
