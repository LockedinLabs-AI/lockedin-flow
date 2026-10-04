//! Framework-independent dictation boundaries. No filesystem, network, or UI access.
#![forbid(unsafe_code)]

pub mod audio;
pub mod vocabulary;

use serde::Serialize;
use zeroize::Zeroize;

pub const MAX_RECORDING_SECONDS: usize = 300;
pub const SAMPLE_RATE: usize = 16_000;
pub const MAX_TRANSCRIPT_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    NeedsModel,
    Loading,
    Ready,
    Recording,
    Transcribing,
    Recovery,
}

/// Only the native worker may move this state machine. UI flags are not authority.
pub struct Session {
    pub phase: Phase,
    transcript: String,
    generation: u64,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            phase: Phase::NeedsModel,
            transcript: String::new(),
            generation: 0,
        }
    }
}

impl Session {
    pub fn start(&mut self) -> Result<u64, &'static str> {
        if self.phase != Phase::Ready {
            return Err("Finish or discard the current recording before starting another.");
        }
        self.generation = self.generation.wrapping_add(1);
        self.phase = Phase::Recording;
        Ok(self.generation)
    }

    pub fn stop(&mut self) -> Result<u64, &'static str> {
        if self.phase != Phase::Recording {
            return Err("There is no active recording to stop.");
        }
        self.phase = Phase::Transcribing;
        Ok(self.generation)
    }

    pub fn complete(&mut self, generation: u64, mut text: String) -> Result<(), &'static str> {
        if self.phase != Phase::Transcribing || self.generation != generation {
            text.zeroize();
            return Err("A stale transcription result was discarded.");
        }
        if text.len() > MAX_TRANSCRIPT_BYTES || text.contains('\0') {
            text.zeroize();
            return Err("The transcription result exceeded the safety limit.");
        }
        if text.trim().is_empty() {
            text.zeroize();
            return Err("No speech was recognized. Your previous transcript is unchanged; retry or discard this recording.");
        }
        self.transcript.zeroize();
        self.transcript = text;
        self.phase = Phase::Ready;
        Ok(())
    }

    pub fn transcript(&self) -> &str {
        &self.transcript
    }

    /// Clear is explicit. Starting a new capture does not erase the last result.
    pub fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.transcript.zeroize();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.transcript.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recording_is_model_gated_and_cannot_overlap() {
        let mut session = Session::default();
        assert!(session.start().is_err());
        session.phase = Phase::Ready;
        assert!(session.start().is_ok());
        assert!(session.start().is_err());
        assert!(session.stop().is_ok());
        assert!(session.stop().is_err());
        assert!(session.start().is_err());
    }

    #[test]
    fn cancellation_invalidates_late_results() {
        let mut session = Session::default();
        session.phase = Phase::Ready;
        let generation = session.start().unwrap();
        session.stop().unwrap();
        session.clear();
        assert!(session
            .complete(generation, "Synthetic example".into())
            .is_err());
        assert_eq!(session.transcript(), "");
    }

    #[test]
    fn previous_result_survives_new_capture_and_duplicate_completion() {
        let mut session = Session::default();
        session.phase = Phase::Ready;
        let first = session.start().unwrap();
        session.stop().unwrap();
        session
            .complete(first, "Synthetic first result".into())
            .unwrap();
        assert!(session.complete(first, "Duplicate".into()).is_err());
        session.start().unwrap();
        assert_eq!(session.transcript(), "Synthetic first result");
    }

    #[test]
    fn invalid_output_never_replaces_the_transcript() {
        for text in ["unsafe\0text".into(), "a".repeat(MAX_TRANSCRIPT_BYTES + 1)] {
            let mut session = Session::default();
            session.phase = Phase::Ready;
            let generation = session.start().unwrap();
            session.stop().unwrap();
            assert!(session.complete(generation, text).is_err());
            assert!(session.transcript().is_empty());
        }
    }

    #[test]
    fn empty_recognition_never_erases_a_previous_result() {
        for text in ["", " \n\t", "\u{2003}"] {
            let mut session = Session::default();
            session.phase = Phase::Ready;
            let first = session.start().unwrap();
            session.stop().unwrap();
            session
                .complete(first, "Synthetic previous result".into())
                .unwrap();
            let next = session.start().unwrap();
            session.stop().unwrap();
            assert!(session.complete(next, text.into()).is_err());
            assert_eq!(session.transcript(), "Synthetic previous result");
        }
    }
}
