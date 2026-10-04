use lockedin_flow_core::{vocabulary::Vocabulary, Phase, Session};
use lockedin_flow_engine::{
    capture::{resample, Capture, Captured},
    model,
    speech::{Recognizer, SpeechEngine},
};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{
        mpsc::{self, Receiver, SyncSender},
        Arc, Mutex,
    },
    time::Duration,
};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub phase: Phase,
    pub message: String,
    pub transcript: String,
    pub seconds: usize,
    pub peak: f32,
    pub vocabulary_count: usize,
    pub model: &'static str,
}

impl Default for View {
    fn default() -> Self {
        Self {
            phase: Phase::Loading,
            message: "Verifying the bundled speech model…".into(),
            transcript: String::new(),
            seconds: 0,
            peak: 0.0,
            vocabulary_count: 0,
            model: model::MODEL_NAME,
        }
    }
}

impl Drop for View {
    fn drop(&mut self) {
        self.transcript.zeroize();
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Start,
    Stop,
    Retry,
    Discard,
    Clear,
    Copy,
    ReloadModel,
}

impl Action {
    pub fn allowed(self, phase: Phase) -> bool {
        match self {
            Self::Start | Self::Clear => phase == Phase::Ready,
            Self::Stop => phase == Phase::Recording,
            Self::Retry => phase == Phase::Recovery,
            Self::Discard => matches!(phase, Phase::Recording | Phase::Recovery),
            Self::Copy => !matches!(phase, Phase::Loading | Phase::Transcribing),
            Self::ReloadModel => matches!(phase, Phase::Ready | Phase::NeedsModel),
        }
    }
}
pub enum Message {
    Action(Action, SyncSender<Result<(), &'static str>>),
    Vocabulary(Zeroizing<String>, SyncSender<Result<(), &'static str>>),
}

pub fn spawn(resources: PathBuf) -> std::io::Result<(SyncSender<Message>, Arc<Mutex<View>>)> {
    let (sender, receiver) = mpsc::sync_channel(8);
    let view = Arc::new(Mutex::new(View::default()));
    let shared = Arc::clone(&view);
    std::thread::Builder::new()
        .name("offline-dictation".into())
        .spawn(move || {
            let mut worker = Worker {
                session: Session::default(),
                view: shared,
                engine: None,
                capture: None,
                recovery: None,
                vocabulary: Vocabulary::default(),
                clipboard: None,
                model_path: resources.join("models").join(model::MODEL_FILE),
            };
            worker.load_model();
            worker.run(receiver);
        })?;
    Ok((sender, view))
}

struct Worker {
    session: Session,
    view: Arc<Mutex<View>>,
    engine: Option<Box<dyn Recognizer>>,
    capture: Option<Capture>,
    recovery: Option<Captured>,
    vocabulary: Vocabulary,
    clipboard: Option<arboard::Clipboard>,
    model_path: PathBuf,
}

impl Worker {
    fn update(&self, message: &str) {
        if let Ok(mut view) = self.view.lock() {
            view.phase = self.session.phase;
            view.message = message.into();
            if view.transcript != self.session.transcript() {
                view.transcript.zeroize();
                view.transcript = self.session.transcript().into();
            }
            view.vocabulary_count = self.vocabulary.count();
            if self.capture.is_none() {
                view.peak = 0.0;
            }
        }
    }

    fn load_model(&mut self) {
        if matches!(
            self.session.phase,
            Phase::Recording | Phase::Transcribing | Phase::Recovery
        ) {
            return;
        }
        self.session.phase = Phase::Loading;
        self.update("Verifying the bundled speech model…");
        match SpeechEngine::load(&self.model_path) {
            Ok(engine) => {
                self.engine = Some(Box::new(engine));
                self.session.phase = Phase::Ready;
                self.update("Ready. Your speech will be processed on this device.");
            }
            Err(error) => {
                self.engine = None;
                self.session.phase = Phase::NeedsModel;
                self.update(error);
            }
        }
    }

    fn run(&mut self, receiver: Receiver<Message>) {
        loop {
            match receiver.recv_timeout(Duration::from_millis(150)) {
                Ok(Message::Action(action, completion)) => {
                    self.complete_action(action, completion);
                }
                Ok(Message::Vocabulary(text, completion)) => {
                    let result = if self.session.phase != Phase::Ready {
                        Err("Finish the current recording before changing vocabulary.")
                    } else {
                        match Vocabulary::parse(&text) {
                            Ok(vocabulary) => {
                                self.vocabulary = vocabulary;
                                self.update(
                                    "Vocabulary applied for this session. It is not saved to disk.",
                                );
                                Ok(())
                            }
                            Err(error) => Err(error),
                        }
                    };
                    if let Err(error) = result {
                        self.update(error);
                    }
                    let _ = completion.try_send(result);
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            if let Some(capture) = &mut self.capture {
                let status = capture.status();
                if let Ok(mut view) = self.view.lock() {
                    view.seconds = status.seconds;
                    view.peak = status.peak;
                }
                if status.stopped {
                    if let Err(error) = self.finish_capture() {
                        self.update(error);
                    }
                }
            }
        }
        // Closing the app drops the stream, recovery audio, vocabulary, and transcript.
    }

    fn action(&mut self, action: Action) -> Result<(), &'static str> {
        match action {
            Action::Start => {
                if self.engine.is_none() {
                    return Err("The speech model is not ready.");
                }
                self.session.start()?;
                match Capture::start() {
                    Ok(capture) => {
                        self.capture = Some(capture);
                        if let Ok(mut view) = self.view.lock() {
                            view.seconds = 0;
                        }
                        self.update("Listening. Stop when you have finished speaking.");
                    }
                    Err(error) => {
                        self.session.phase = Phase::Ready;
                        return Err(error);
                    }
                }
            }
            Action::Stop => self.finish_capture()?,
            Action::Retry => {
                if self.session.phase != Phase::Recovery {
                    return Err("There is no recording to retry.");
                }
                self.session.phase = Phase::Recording;
                let generation = self.session.stop()?;
                self.transcribe(generation)?;
            }
            Action::Discard => {
                if !matches!(self.session.phase, Phase::Recording | Phase::Recovery) {
                    return Err("There is no recording to discard.");
                }
                self.capture.take();
                self.recovery.take();
                self.session.phase = Phase::Ready;
                self.update("Recording discarded. The previous transcript is unchanged.");
            }
            Action::Clear => {
                if self.session.phase != Phase::Ready {
                    return Err("Finish the current recording before clearing its transcript.");
                }
                self.session.clear();
                self.update("Transcript cleared from this session. Previously copied text is still managed by your clipboard.");
            }
            Action::Copy => {
                if self.session.transcript().is_empty() {
                    return Err("There is no transcript to copy.");
                }
                if self.clipboard.is_none() {
                    self.clipboard = Some(arboard::Clipboard::new().map_err(|_| {
                        "Clipboard access is unavailable. Select and copy the transcript manually."
                    })?);
                }
                if let Some(clipboard) = &mut self.clipboard {
                    copy_with_privacy_hints(clipboard, self.session.transcript()).map_err(
                        |_| "The transcript could not be copied. Select and copy it manually.",
                    )?;
                }
                self.update("Copied. Your destination app and clipboard manager control any further sharing.");
            }
            Action::ReloadModel => self.load_model(),
        }
        Ok(())
    }

    fn complete_action(
        &mut self,
        action: Action,
        completion: SyncSender<Result<(), &'static str>>,
    ) {
        let result = self.action(action);
        if let Err(error) = result {
            self.update(error);
        }
        // The IPC promise resolves after state and user-visible text are updated,
        // not merely after enqueueing. A closed window must never block capture.
        let _ = completion.try_send(result);
    }

    fn finish_capture(&mut self) -> Result<(), &'static str> {
        let generation = self.session.stop()?;
        let Some(capture) = self.capture.take() else {
            self.session.phase = if self.recovery.is_some() {
                Phase::Recovery
            } else {
                Phase::Ready
            };
            return Err(
                "Microphone capture is unavailable. Your previous transcript is unchanged.",
            );
        };
        match capture.stop() {
            Ok(recording) => self.accept_recording(generation, recording),
            Err(error) => {
                self.session.phase = Phase::Ready;
                Err(error)
            }
        }
    }

    fn accept_recording(
        &mut self,
        generation: u64,
        recording: Captured,
    ) -> Result<(), &'static str> {
        if recording.samples.is_empty() {
            self.session.phase = Phase::Ready;
            return Err("The microphone did not deliver audio. Check your input device and try again. Your previous transcript is unchanged.");
        }
        self.recovery = Some(recording);
        self.transcribe(generation)
    }

    fn transcribe(&mut self, generation: u64) -> Result<(), &'static str> {
        self.update("Transcribing on this device. No audio is being uploaded.");
        let result = match (&self.engine, &self.recovery) {
            (Some(engine), Some(recording)) => resample(&recording.samples, recording.sample_rate)
                .map(Zeroizing::new)
                .and_then(|samples| engine.recognize(&samples)),
            _ => Err("The local engine or recording is unavailable."),
        };
        match result {
            Ok(raw) => {
                let raw = Zeroizing::new(raw);
                if let Err(error) = self
                    .session
                    .complete(generation, self.vocabulary.apply(&raw))
                {
                    self.session.phase = Phase::Recovery;
                    return Err(error);
                }
                let message = match &self.recovery {
                    Some(recording) if recording.interrupted => "Microphone interrupted. The audio captured before the interruption was transcribed; review it for missing speech.",
                    Some(recording) if recording.limit_reached => "The five-minute recording limit was reached. Your captured speech is ready to review.",
                    _ => "Transcript ready. Review it, then copy it to your editor or agent.",
                };
                self.update(message);
                self.recovery.take();
                Ok(())
            }
            Err(error) => {
                self.session.phase = Phase::Recovery;
                Err(error)
            }
        }
    }
}

fn copy_with_privacy_hints(
    clipboard: &mut arboard::Clipboard,
    text: &str,
) -> Result<(), arboard::Error> {
    let setter = clipboard.set();
    #[cfg(target_os = "windows")]
    let setter = {
        use arboard::SetExtWindows;
        setter.exclude_from_monitoring()
    };
    #[cfg(target_os = "linux")]
    let setter = {
        use arboard::SetExtLinux;
        setter.exclude_from_history()
    };
    #[cfg(target_os = "macos")]
    let setter = {
        use arboard::SetExtApple;
        setter.exclude_from_history()
    };
    // These OS/desktop conventions are not enforcement against unrelated clipboard clients.
    setter.text(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct TestRecognizer {
        calls: Cell<usize>,
        fail_once: bool,
    }
    impl Recognizer for TestRecognizer {
        fn recognize(&self, samples: &[f32]) -> Result<String, &'static str> {
            assert_eq!(samples.len(), 16_000);
            let calls = self.calls.get();
            self.calls.set(calls + 1);
            if self.fail_once && calls == 0 {
                Err("Synthetic recognizer failure")
            } else {
                Ok("Synthetic cube control example.".into())
            }
        }
    }

    fn worker(fail_once: bool) -> Worker {
        let mut session = Session::default();
        session.phase = Phase::Ready;
        Worker {
            session,
            view: Arc::new(Mutex::new(View::default())),
            engine: Some(Box::new(TestRecognizer {
                calls: Cell::new(0),
                fail_once,
            })),
            capture: None,
            recovery: Some(Captured {
                samples: Zeroizing::new(vec![0.1; 16_000]),
                sample_rate: 16_000,
                interrupted: false,
                limit_reached: false,
            }),
            vocabulary: Vocabulary::parse("cube control = kubectl").unwrap(),
            clipboard: None,
            model_path: PathBuf::from("synthetic-model-not-opened.bin"),
        }
    }

    #[test]
    fn failed_transcription_retains_audio_and_retry_completes_once() {
        let mut worker = worker(true);
        let generation = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        assert!(worker.transcribe(generation).is_err());
        assert_eq!(worker.session.phase, Phase::Recovery);
        assert_eq!(worker.recovery.as_ref().unwrap().samples.len(), 16_000);
        worker.action(Action::Retry).unwrap();
        assert_eq!(worker.session.phase, Phase::Ready);
        assert_eq!(worker.session.transcript(), "Synthetic kubectl example.");
        assert!(worker.recovery.is_none());
        assert!(worker.clipboard.is_none());
        assert!(worker.action(Action::Retry).is_err());
    }

    #[test]
    fn interrupted_audio_completes_with_an_explicit_partial_notice() {
        let mut worker = worker(false);
        worker.recovery.as_mut().unwrap().interrupted = true;
        let generation = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        worker.transcribe(generation).unwrap();
        assert!(worker
            .view
            .lock()
            .unwrap()
            .message
            .starts_with("Microphone interrupted."));
        assert!(worker.recovery.is_none());
    }

    #[test]
    fn conversion_failure_keeps_original_samples_for_recovery() {
        let mut worker = worker(false);
        worker.recovery.as_mut().unwrap().sample_rate = 0;
        let generation = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        assert!(worker.transcribe(generation).is_err());
        assert_eq!(worker.session.phase, Phase::Recovery);
        assert_eq!(worker.recovery.as_ref().unwrap().samples.len(), 16_000);
        worker.recovery.as_mut().unwrap().sample_rate = 16_000;
        worker.action(Action::Retry).unwrap();
        assert_eq!(worker.session.transcript(), "Synthetic kubectl example.");
        assert!(worker.recovery.is_none());
    }

    #[test]
    fn discard_drops_recovery_without_touching_the_clipboard() {
        let mut worker = worker(false);
        worker.session.phase = Phase::Recovery;
        worker.action(Action::Discard).unwrap();
        assert!(worker.recovery.is_none());
        assert!(worker.clipboard.is_none());
        assert_eq!(worker.session.phase, Phase::Ready);
    }

    #[test]
    fn missing_capture_does_not_leave_processing_stuck() {
        let mut worker = worker(false);
        worker.recovery = None;
        worker.session.start().unwrap();
        assert!(worker.finish_capture().is_err());
        assert_eq!(worker.session.phase, Phase::Ready);
        assert!(worker.capture.is_none());
    }

    #[test]
    fn microphone_with_no_samples_returns_to_ready_without_erasing_text() {
        let mut worker = worker(false);
        let previous = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        worker.transcribe(previous).unwrap();
        let next = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        let empty = Captured {
            samples: Zeroizing::new(Vec::new()),
            sample_rate: 16_000,
            interrupted: true,
            limit_reached: false,
        };
        assert!(worker.accept_recording(next, empty).is_err());
        assert_eq!(worker.session.phase, Phase::Ready);
        assert_eq!(worker.session.transcript(), "Synthetic kubectl example.");
        assert!(worker.recovery.is_none());
        assert!(worker.clipboard.is_none());
    }

    #[test]
    fn empty_engine_result_keeps_both_audio_and_previous_transcript() {
        struct EmptyRecognizer;
        impl Recognizer for EmptyRecognizer {
            fn recognize(&self, _: &[f32]) -> Result<String, &'static str> {
                Ok(" \n".into())
            }
        }
        let mut worker = worker(false);
        let first = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        worker
            .session
            .complete(first, "Synthetic previous result.".into())
            .unwrap();
        worker.engine = Some(Box::new(EmptyRecognizer));
        let next = worker.session.start().unwrap();
        worker.session.stop().unwrap();
        assert!(worker.transcribe(next).is_err());
        assert_eq!(worker.session.phase, Phase::Recovery);
        assert_eq!(worker.session.transcript(), "Synthetic previous result.");
        assert_eq!(worker.recovery.as_ref().unwrap().samples.len(), 16_000);
        assert!(worker.clipboard.is_none());
    }

    #[test]
    fn ipc_cannot_queue_future_recordings_while_processing() {
        for action in [
            Action::Start,
            Action::Stop,
            Action::Retry,
            Action::Discard,
            Action::Clear,
            Action::Copy,
            Action::ReloadModel,
        ] {
            assert!(!action.allowed(Phase::Transcribing));
            assert!(!action.allowed(Phase::Loading));
        }
        assert!(!Action::Start.allowed(Phase::NeedsModel));
        assert!(!Action::Start.allowed(Phase::Recording));
        assert!(!Action::Start.allowed(Phase::Recovery));
        assert!(Action::Start.allowed(Phase::Ready));
    }

    #[test]
    fn action_acknowledgement_follows_updated_state_and_reports_failure() {
        let mut worker = worker(false);
        worker.session.phase = Phase::Recovery;
        let (sender, receiver) = mpsc::sync_channel(1);
        worker.complete_action(Action::Discard, sender);
        assert_eq!(receiver.recv().unwrap(), Ok(()));
        assert_eq!(worker.view.lock().unwrap().phase, Phase::Ready);
        assert!(worker.recovery.is_none());
        let (sender, receiver) = mpsc::sync_channel(1);
        worker.complete_action(Action::Retry, sender);
        assert!(receiver.recv().unwrap().is_err());
        assert_eq!(worker.session.phase, Phase::Ready);
    }

    #[test]
    fn closed_ui_does_not_block_worker_completion() {
        let mut worker = worker(false);
        worker.session.phase = Phase::Recovery;
        let (sender, receiver) = mpsc::sync_channel(1);
        drop(receiver);
        worker.complete_action(Action::Discard, sender);
        assert_eq!(worker.session.phase, Phase::Ready);
        assert!(worker.recovery.is_none());
    }
}
