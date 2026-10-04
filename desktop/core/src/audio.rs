//! Bounded capture storage. A device error preserves the samples already captured.
use crate::MAX_RECORDING_SECONDS;
use std::time::Duration;
use zeroize::Zeroize;

/// A stream can stop delivering callbacks without reporting a device error.
/// The adapter supplies monotonic elapsed time; this core policy is device-independent.
#[derive(Default)]
pub struct CaptureProgress {
    samples: usize,
    last_progress: Duration,
}

impl CaptureProgress {
    pub const STALL_TIMEOUT: Duration = Duration::from_secs(5);

    pub fn stalled(&mut self, samples: usize, elapsed: Duration) -> bool {
        if samples > self.samples {
            self.samples = samples;
            self.last_progress = elapsed;
        }
        elapsed.saturating_sub(self.last_progress) >= Self::STALL_TIMEOUT
    }
}

pub struct CaptureBuffer {
    samples: Vec<f32>,
    limit: usize,
    pub interrupted: bool,
    pub full: bool,
    pub peak: f32,
}

impl CaptureBuffer {
    pub fn new(rate: u32) -> Result<Self, &'static str> {
        if !(8_000..=192_000).contains(&rate) {
            return Err("This microphone sample rate is not supported.");
        }
        let limit = rate as usize * MAX_RECORDING_SECONDS;
        let mut samples = Vec::new();
        samples
            .try_reserve_exact(limit)
            .map_err(|_| "Not enough memory to start recording.")?;
        Ok(Self {
            samples,
            limit,
            interrupted: false,
            full: false,
            peak: 0.0,
        })
    }

    /// No allocation on the capture callback. Invalid frames stop capture, not silently disappear.
    pub fn push_interleaved<T>(&mut self, input: &[T], channels: usize, convert: impl Fn(T) -> f32)
    where
        T: Copy,
    {
        if self.interrupted || self.full {
            return;
        }
        if channels == 0 || channels > 32 || !input.len().is_multiple_of(channels) {
            self.interrupted = true;
            return;
        }
        self.peak = 0.0;
        for frame in input.chunks_exact(channels) {
            if self.samples.len() == self.limit {
                self.full = true;
                break;
            }
            let mut mono = 0.0;
            for sample in frame {
                let value = convert(*sample);
                if !value.is_finite() {
                    self.interrupted = true;
                    return;
                }
                mono += value.clamp(-1.0, 1.0) / channels as f32;
            }
            self.peak = self.peak.max(mono.abs());
            self.samples.push(mono);
        }
        self.full |= self.samples.len() == self.limit;
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }
    pub fn take(&mut self) -> Vec<f32> {
        std::mem::take(&mut self.samples)
    }
}

impl Drop for CaptureBuffer {
    fn drop(&mut self) {
        self.samples.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn downmix_and_invalid_frames_preserve_captured_audio() {
        let mut buffer = CaptureBuffer::new(16_000).unwrap();
        buffer.push_interleaved(&[1.0, -1.0, 0.25, 0.75], 2, |v| v);
        buffer.push_interleaved(&[f32::NAN], 1, |v| v);
        buffer.push_interleaved(&[0.9], 1, |v| v);
        assert!(buffer.interrupted);
        assert_eq!(buffer.take(), [0.0, 0.5]);
    }

    #[test]
    fn duration_limit_is_enforced_without_overrun() {
        let mut buffer = CaptureBuffer::new(8_000).unwrap();
        let frame = vec![0.1; 8_000];
        for _ in 0..MAX_RECORDING_SECONDS + 5 {
            buffer.push_interleaved(&frame, 1, |v| v);
        }
        assert_eq!(buffer.len(), 8_000 * MAX_RECORDING_SECONDS);
        assert!(buffer.full);
    }

    #[test]
    fn channels_rates_and_nonfinite_values_are_validated() {
        assert!(CaptureBuffer::new(0).is_err());
        assert!(CaptureBuffer::new(u32::MAX).is_err());
        for channels in [0, 2, 33] {
            let mut buffer = CaptureBuffer::new(16_000).unwrap();
            buffer.push_interleaved(&[0.1], channels, |v| v);
            assert!(buffer.interrupted);
        }
    }

    #[test]
    fn stream_that_never_delivers_audio_times_out() {
        let mut progress = CaptureProgress::default();
        assert!(!progress.stalled(0, Duration::from_millis(4_999)));
        assert!(progress.stalled(0, Duration::from_secs(5)));
    }

    #[test]
    fn new_samples_reset_the_stall_timeout_but_polling_does_not() {
        let mut progress = CaptureProgress::default();
        assert!(!progress.stalled(16_000, Duration::from_secs(1)));
        assert!(!progress.stalled(16_000, Duration::from_secs(5)));
        assert!(!progress.stalled(32_000, Duration::from_secs(5)));
        assert!(!progress.stalled(32_000, Duration::from_secs(9)));
        assert!(progress.stalled(32_000, Duration::from_secs(10)));
    }

    #[test]
    fn active_stream_and_large_monotonic_gap_are_handled() {
        let mut progress = CaptureProgress::default();
        for second in 1..=MAX_RECORDING_SECONDS {
            assert!(!progress.stalled(second * 16_000, Duration::from_secs(second as u64)));
        }
        assert!(progress.stalled(MAX_RECORDING_SECONDS * 16_000, Duration::from_secs(600)));
    }
}
