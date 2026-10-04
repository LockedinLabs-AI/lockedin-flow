import AppKit
import AudioCapture
import InsertionEngine
import SpeechEngine
import TextIntelligence
import VoiceCore

/// How dictation is activated from the keyboard.
enum ActivationMode: String, CaseIterable, Identifiable {
    /// Hold the key to record, release to transcribe and insert.
    case hold
    /// Press once to start, press again (or pause) to stop.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to start / press to stop"
        }
    }
}

struct ReinsertSuccess: Sendable, Equatable {
    let appName: String
    let requiresClipboardInspection: Bool
    let completedBeforeCancellation: Bool

    init(
        appName: String,
        requiresClipboardInspection: Bool,
        completedBeforeCancellation: Bool = false
    ) {
        self.appName = appName
        self.requiresClipboardInspection = requiresClipboardInspection
        self.completedBeforeCancellation = completedBeforeCancellation
    }

    var compactMessage: String {
        if completedBeforeCancellation {
            return requiresClipboardInspection
                ? "Inserted in \(appName) before cancellation — check clipboard"
                : "Inserted in \(appName) before cancellation"
        }
        return requiresClipboardInspection
            ? "Inserted in \(appName) — check clipboard"
            : "Inserted in \(appName)"
    }

    var statusMessage: String {
        if completedBeforeCancellation {
            return requiresClipboardInspection
                ? "Inserted in \(appName) before cancellation. Do not retry; inspect the original field and clipboard before continuing."
                : "Inserted in \(appName) before cancellation. Do not retry the insertion."
        }
        return requiresClipboardInspection
            ? "Inserted in \(appName). Check the clipboard before continuing because its final state could not be verified."
            : "Inserted in \(appName)."
    }

    var requiresInspectionAcknowledgement: Bool {
        requiresClipboardInspection || completedBeforeCancellation
    }
}

/// Content-free identity and guidance for one re-insertion that must be
/// inspected before another attempt is enabled. The opaque inspection token is
/// bound to the originating task lease; `sourceID` associates History/Home
/// rows without retaining transcript text.
struct ReinsertInspectionNotice: Sendable, Equatable {
    let inspection: ReinsertTaskGate.Inspection
    let sourceID: UUID?
    let message: String
}

/// Completion-safe presentation for a re-insertion whose delivery or clipboard
/// rollback is uncertain. UI callers receive the same terminal guidance and an
/// acknowledgment token instead of an immediately retryable generic failure.
struct ReinsertSafetyNoticeError: LocalizedError {
    let notice: ReinsertInspectionNotice

    var errorDescription: String? { notice.message }
}

/// Orchestrates the dictation pipeline:
/// hotkey → capture → STT → cleanup → vocabulary → insertion → recovery/history.
@MainActor
final class DictationController {
    private enum RetryKind: Equatable {
        case dictation
        case meeting
    }

    /// Delivery application and formatting semantics retained for one dictation.
    /// The application lock is captured when recording ends, but the concrete
    /// Accessibility field is deliberately resolved only at the insertion
    /// boundary. Renderer remounts during recording therefore cannot invalidate
    /// a dictation, while a later application switch still fails closed.
    private struct DictationContext {
        let targetSnapshot: InsertionTargetSnapshot?
        let localProfile: AppProfile
        let deliveryMode: DictationDeliveryMode
        let captureWasInterrupted: Bool

        var focusLock: InsertionFocusLock? { targetSnapshot?.focusLock }
        var profile: AppProfile { targetSnapshot?.profile ?? localProfile }
    }

    private struct UsableCapture {
        let samples: [Float]
        let wasInterrupted: Bool
    }

    private weak var state: AppState?

    private let capture: AudioCaptureManager
    private let inserter = TextInserter()
    private let commandParser = SpokenCommandParser()
    private var stt: any STTProviding
    private let audioPreparer = VoiceAwareAudioPreparer()
    private var vocabulary: Vocabulary
    private var snippets: SnippetLibrary
    private var pipelineTask: Task<Void, Never>?
    /// Re-insert actions are independent from the capture pipeline but still
    /// suspend in focus recovery and paste receipt. Keep their task and lease
    /// together so Cancel stops pre-event work promptly but cannot expose a
    /// retry while an already-dispatched paste is still resolving.
    private let reinsertTaskGate = ReinsertTaskGate()
    private var retryBuffer = InMemoryDictationRetryBuffer()
    private var retryKind: RetryKind = .dictation
    private var retryDictationContext: DictationContext?
    private var retryMeetingCaptureWasInterrupted = false
    private var activePipelineSamples: [Float]?
    private var activePipelineKind: RetryKind?
    private var activeDictationContext: DictationContext?
    private var activeCaptureWasInterrupted = false
    private var captureStartGate = CaptureStartGate()
    private var meetingPipelineToken: UUID?
    private var resetToken: UUID?
    /// Guards the opt-in post-insertion edit watch; a new capture or a new
    /// watch invalidates any watch still sleeping.
    private var editWatchToken: UUID?
    private var captureDeliveryMode: DictationDeliveryMode = .inApp

    // Silence auto-stop (toggle mode only)
    private var heardSpeech = false
    private var lastLoudAt = Date.distantPast
    private let maxDictationSeconds: TimeInterval = 600
    private var levelWatchTask: Task<Void, Never>?

    init(state: AppState) {
        self.capture = AudioCaptureManager(
            voiceProcessing: state.voiceFocusEnabled ? .automatic : .disabled
        )
        self.state = state
        self.stt = SpeechModelFactory.make(.multilingual)
        self.vocabulary = VocabularyStore.load()
        self.snippets = SnippetStore.load()
        capture.onLevel = { [weak self, weak state] level in
            Task { @MainActor in
                guard state?.pipelineState == .recording else { return }
                state?.level = level
                self?.noteLevel(level)
            }
        }
    }

    func setVoiceFocusEnabled(_ enabled: Bool) {
        capture.setVoiceProcessingPreference(enabled ? .automatic : .disabled)
    }

    var modelDisplayName: String { stt.modelDisplayName }
    var modelShortName: String {
        SpeechModelChoice(rawValue: stt.modelID)?.shortName ?? stt.modelDisplayName
    }
    var isVoiceProcessingActive: Bool { capture.isVoiceProcessingActive }

    func prepareSTT(for choice: SpeechModelChoice) async throws {
        if stt.modelID == choice.rawValue {
            try await stt.prepare()
            return
        }

        // Prepare the candidate completely before swapping it in. A failed
        // provisioning check or model load leaves the current provider intact.
        let candidate = SpeechModelFactory.make(choice)
        try await candidate.prepare()
        stt = candidate
    }

    func prewarmVoiceActivityDetection() async {
        await audioPreparer.prewarm()
    }

    /// Called when the vocabulary editor saves changes.
    func reloadVocabulary() {
        vocabulary = VocabularyStore.load()
    }

    // MARK: - Learn corrections from edits (opt-in)

    /// Briefly watches the exact control a dictation was just inserted into so
    /// the person's own fix — correcting a name, for example — can be learned
    /// as a vocabulary rule. Runs only when the person enabled the setting,
    /// checks three times over thirty seconds, and
    /// compares values in memory only. The baseline read happens immediately
    /// so surrounding pre-existing text is never mistaken for an edit.
    private func beginEditWatch(
        target: CapturedInsertionTarget,
        insertedText: String,
        state: AppState
    ) {
        guard let baseline = inserter.editWatchValue(of: target), !baseline.isEmpty else {
            return
        }
        let token = UUID()
        editWatchToken = token
        Task { [weak self] in
            for delay: UInt64 in [4_000_000_000, 8_000_000_000, 18_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.editWatchToken == token else { return }
                guard state.automaticInsertionEnabled, state.learnFromEditsEnabled else { return }
                guard let current = self.inserter.editWatchValue(of: target) else { return }
                guard current != baseline else { continue }
                guard
                    let correction = EditCorrectionDetector.detect(
                        inserted: baseline,
                        edited: current,
                        insertedSpan: insertedText
                    )
                else { continue }
                self.editWatchToken = nil
                self.learnCorrectionFromEdit(correction, state: state)
                return
            }
            guard let self, self.editWatchToken == token else { return }
            self.editWatchToken = nil
        }
    }

    private func learnCorrectionFromEdit(
        _ correction: EditLearnedCorrection,
        state: AppState
    ) {
        let vocabulary = VocabularyStore.load()
        let spokenKey = correction.spoken.lowercased()
        guard !vocabulary.rules.contains(where: { $0.spoken.lowercased() == spokenKey }) else {
            return
        }
        let rule = VocabularyRule(
            spoken: correction.spoken,
            written: correction.written
        )
        do {
            try VocabularyStore.addRule(rule)
            reloadVocabulary()
            state.showVocabularyToast(
                spoken: correction.spoken,
                written: correction.written,
                ruleID: rule.id
            )
        } catch {
            FlowLog.error("edit-learning could not save the vocabulary rule")
        }
    }

    /// Called when the snippets editor saves changes.
    func reloadSnippets() {
        snippets = SnippetStore.load()
    }

    // MARK: - Meeting mode (opt-in feature: mic-only v1)

    /// Meeting mode records until stopped (no silence auto-stop, 60-minute cap),
    /// then produces structured notes with the on-device model. No system audio,
    /// no Screen Recording permission — the Mac's mic hears the room.
    func toggleMeeting() {
        guard let state else { return }
        // An active meeting must always remain stoppable, even if a profile
        // change was requested while it was recording.
        if state.isMeetingRecording {
            stopMeeting()
            return
        }
        guard state.meetingNotesEnabled else { return }
        startMeeting()
    }

    private func completeInsertion(
        raw originalRaw: String,
        final originalFinal: String,
        duration: TimeInterval,
        context: DictationContext,
        state: AppState
    ) async {
        var raw = originalRaw
        var final = originalFinal
        // Recovery records only the clipboard's content-free generation.
        // Representations are read later only at an authorized automatic-write
        // boundary whose generation is still unchanged.
        var clipboardWriteOutcome: PasteboardWriteOutcome?
        state.pipelineState = .inserting

        do {
            guard let focusLock = context.focusLock else {
                throw InsertionError.noTargetApplication
            }
            let appName = focusLock.appName

            // Resolve the concrete field only after transcription and cleanup
            // have completed. The delivery API acquires the pasteboard lease
            // before target capture, so no AX field survives recording or waits
            // behind another insertion. The application lock was frozen when
            // recording ended, so an intervening app switch is still rejected.
            let keepOnClipboard = state.autoCopyEnabled
            let delivery = try await inserter.insertOrdinaryAtCurrentTarget(
                final,
                into: focusLock,
                restoreClipboard: !keepOnClipboard
            )
            let result = delivery.result
            let insertionTarget = delivery.target
            if Task.isCancelled {
                // Delivery is already confirmed, so Cancel may suppress every
                // persistence/copy effect but must not imply that
                // nothing reached the target.
                raw.removeAll(keepingCapacity: false)
                final.removeAll(keepingCapacity: false)
                activeDictationContext = nil
                state.statusMessage = nil
                state.errorMessage =
                    Self
                    .confirmedDeliveryCancellationSafetyNotice(for: result)
                return
            }
            state.lastRaw = raw
            state.lastFinal = final
            if result.clipboardDisposition
                == .pasteTransportRestorationUnverified
            {
                // Delivery itself was conclusively confirmed. Keep the
                // pipeline successful and surface only the clipboard warning;
                // treating this as retryable could duplicate the insertion.
                clipboardWriteOutcome = .outcomeUnverified
            }
            if keepOnClipboard {
                switch result.clipboardDisposition {
                case let .copyIfUnchanged(expectedChangeCount):
                    // AX insertion never stages text. Honor auto-copy only if
                    // the clipboard generation is still the one observed after
                    // AX verification; an explicit user copy always wins.
                    clipboardWriteOutcome = writePasteboardString(
                        final,
                        ifChangeCountMatches: expectedChangeCount
                    )
                case .newerExternalContentPreserved:
                    clipboardWriteOutcome = .newerContentPreserved
                case .pasteTransportManaged:
                    // Paste transport has already retained the transcript when
                    // auto-copy is enabled and still owns the pasteboard.
                    break
                case .pasteTransportRestorationUnverified:
                    // `clipboardWriteOutcome` above preserves the successful
                    // delivery while warning about restoration.
                    break
                }
            }

            let captureOutcomeSuffix = context.captureWasInterrupted ? ":partial-audio" : ""
            recordHistory(
                raw: raw,
                final: final,
                duration: duration,
                appName: appName,
                profile: context.profile,
                state: state,
                outcome: "inserted:\(result.method.rawValue)\(captureOutcomeSuffix)"
            )
            RecoveryStore.shared.record(
                raw: raw,
                final: final,
                targetAppName: appName,
                status: "inserted:\(result.method.rawValue)\(captureOutcomeSuffix)"
            )

            let wordCount = final.split(separator: " ").count
            state.wordsThisSession += wordCount
            state.pipelineState = .done
            state.overlayTone = .success
            switch clipboardWriteOutcome {
            case .newerContentPreserved:
                state.statusMessage =
                    "Inserted. The clipboard was not replaced; the transcript remains in LockedIn Flow."
            case .originalContentsRestored:
                state.statusMessage =
                    "Inserted. The prior clipboard was restored; the transcript remains in LockedIn Flow."
            case .clipboardUnchanged:
                state.statusMessage =
                    "Inserted. Auto-copy was unavailable, so the clipboard was left unchanged."
            case .outcomeUnverified:
                state.statusMessage =
                    "Inserted. Check the clipboard before continuing because its final state could not be verified."
            case .written, .none:
                break
            }
            if context.captureWasInterrupted {
                let interruptionNotice =
                    "The microphone was interrupted. Only the audio captured before the interruption was inserted; review the ending."
                if let currentStatus = state.statusMessage, !currentStatus.isEmpty {
                    state.statusMessage = currentStatus + " " + interruptionNotice
                } else {
                    state.statusMessage = interruptionNotice
                }
            }
            activeDictationContext = nil
            activeCaptureWasInterrupted = false
            // Delivery diagnostics must not depend on transcript content,
            // including its length. Keep completion as a fixed event.
            FlowLog.pipeline("dictation inserted")
            if state.learnFromEditsEnabled,
                insertionTarget.supportsExactPostDeliveryObservation
            {
                beginEditWatch(target: insertionTarget, insertedText: final, state: state)
            }
        } catch {
            let cancellationSafetyNotice =
                Self
                .cancellationSafetyNotice(for: error)
            if error is CancellationError || Task.isCancelled {
                // Explicit cancellation is terminal for this transcript. Do
                // not let an async target/readiness or receipt cancellation
                // resurrect it as a failed dictation in History, Recovery, or
                // the clipboard after `cancel()` has returned the UI to ready.
                // If delivery had already begun, surface only the terminal
                // inspection notice; never restore retry or persistence state.
                raw.removeAll(keepingCapacity: false)
                final.removeAll(keepingCapacity: false)
                activeDictationContext = nil
                if let cancellationSafetyNotice {
                    state.statusMessage = nil
                    state.errorMessage = cancellationSafetyNotice
                }
                FlowLog.info("cancelled insertion discarded without recovery")
                return
            }
            let insertionError = error as? InsertionError
            if insertionError?.requiresSensitiveContentDiscard == true {
                raw.removeAll(keepingCapacity: false)
                final.removeAll(keepingCapacity: false)
                state.statusMessage = nil
                FlowLog.info("sensitive insertion outcome; transcript discarded")
            } else {
                FlowLog.error("insertion failed code=\(errorCode: error)")
                let appName = context.focusLock?.appName
                state.lastRaw = raw
                state.lastFinal = final
                recordHistory(
                    raw: raw,
                    final: final,
                    duration: duration,
                    appName: appName,
                    profile: context.profile,
                    state: state,
                    outcome: "failed"
                )
                RecoveryStore.shared.record(
                    raw: raw,
                    final: final,
                    targetAppName: appName,
                    status: "failed:\(error.localizedDescription)"
                )
                if insertionError?.requiresExternalClipboardPreservation == true {
                    clipboardWriteOutcome =
                        switch insertionError {
                        case .clipboardRestorationUnverified,
                            .insertionAndClipboardRestorationUnverified:
                            .outcomeUnverified
                        default:
                            .newerContentPreserved
                        }
                } else {
                    // A recoverable insertion failure must not create an
                    // implicit clipboard export. The transcript remains
                    // available in LockedIn Flow for an explicit retry or
                    // copy from History.
                    clipboardWriteOutcome = .clipboardUnchanged
                }
            }

            state.errorMessage = Self.insertionFailureMessage(
                for: error,
                clipboardWriteOutcome: clipboardWriteOutcome
            )
            state.pipelineState = .failed
            state.overlayTone = .failure
            activeDictationContext = nil
            activeCaptureWasInterrupted = false
        }
    }

    private func startMeeting() {
        guard let state, state.modelReady,
            !captureStartGate.hasPendingAttempt,
            isCaptureStartAllowed(state.pipelineState)
        else { return }
        invalidatePendingReset()
        guard
            let token = captureStartGate.begin(
                requiresHeldTrigger: false
            )
        else { return }
        state.errorMessage = nil
        Task {
            defer {
                captureStartGate.finish(token)
            }
            guard captureStartGate.permitsStart(for: token) else { return }
            let microphoneIsAuthorized = await AudioCaptureManager.microphoneAuthorized()
            guard captureStartGate.permitsStart(for: token),
                isCaptureStartAllowed(state.pipelineState)
            else { return }
            guard microphoneIsAuthorized else {
                state.errorMessage = "Microphone permission is required."
                return
            }
            do {
                try capture.start()
            } catch {
                state.errorMessage = error.localizedDescription
                return
            }
            // A new capture replaces any failed dictation or meeting retained for
            // retry. Raw audio remains session-only and is never persisted.
            clearFailedDictationRetry()
            state.isMeetingRecording = true
            state.updatePipelineMeetingState(true)
            state.pipelineState = .recording
            state.overlayTone = .recording
            state.recordingStartedAt = Date()
            startMeetingWatch()
        }
    }

    private func startMeetingWatch() {
        levelWatchTask?.cancel()
        levelWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let state = self.state, state.isMeetingRecording else { return }
                guard self.keepCaptureHealthy(for: state, isMeeting: true) else { return }
                if self.capture.capturedDuration >= 3_600 {
                    self.stopMeeting()
                    return
                }
            }
        }
    }

    private func stopMeeting(captureResult: AudioCaptureStopResult? = nil) {
        guard let state, state.isMeetingRecording else { return }
        levelWatchTask?.cancel()
        let result = captureResult ?? capture.stopWithResult()
        guard
            let capture = usableSamples(
                from: result,
                state: state,
                isMeeting: true
            )
        else { return }
        state.isMeetingRecording = false
        processMeeting(
            capture.samples,
            captureWasInterrupted: capture.wasInterrupted
        )
    }

    /// Transcribes a completed meeting with a duration-aware watchdog budget.
    /// As soon as speech-to-text succeeds, the raw transcript is encrypted and
    /// persisted before optional summarization begins.
    private func processMeeting(
        _ samples: [Float],
        captureWasInterrupted: Bool = false
    ) {
        guard let state else { return }
        invalidatePendingReset()
        let token = UUID()
        meetingPipelineToken = token
        let duration = Double(samples.count) / AudioCaptureManager.targetSampleRate
        activePipelineSamples = samples
        activePipelineKind = .meeting
        activeDictationContext = nil
        activeCaptureWasInterrupted = captureWasInterrupted
        state.updatePipelineMeetingState(true)
        state.level = 0
        state.recordingStartedAt = nil
        state.processingBudgetSeconds = max(180, 120 + duration * 0.75)
        state.pipelineState = .transcribing
        state.overlayTone = .working

        pipelineTask = Task {
            defer { activeCaptureWasInterrupted = false }
            do {
                let raw = try await stt.transcribe(samples)
                guard !Task.isCancelled, meetingPipelineToken == token else { return }
                guard !raw.isEmpty else {
                    finishMeetingPipeline(token)
                    activePipelineSamples = nil
                    activePipelineKind = nil
                    if AudioCaptureManager.isSilentCapture(samples) {
                        clearFailedDictationRetry()
                        state.errorMessage = "Nothing heard — meeting discarded."
                    } else {
                        retainFailedDictationForRetry(
                            samples,
                            state: state,
                            kind: .meeting,
                            captureWasInterrupted: captureWasInterrupted
                        )
                        state.errorMessage =
                            "No speech was recognized. The meeting is available to retry."
                    }
                    state.pipelineState = .failed
                    state.overlayTone = .failure
                    resetToReadySoon()
                    return
                }

                let preserved = Meeting(
                    durationSeconds: duration,
                    rawTranscript: raw,
                    note: MeetingNote(
                        title: "Meeting transcript",
                        summary:
                            "The complete transcript is preserved. Structured notes were not completed.",
                        keyPoints: [],
                        actionItems: []
                    )
                )
                do {
                    try await MeetingStore.shared.record(preserved)
                } catch {
                    guard !Task.isCancelled, meetingPipelineToken == token else { return }
                    finishMeetingPipeline(token)
                    retainFailedDictationForRetry(
                        samples,
                        state: state,
                        kind: .meeting,
                        captureWasInterrupted: captureWasInterrupted
                    )
                    activePipelineSamples = nil
                    activePipelineKind = nil
                    state.errorMessage =
                        "The meeting transcript could not be saved: \(error.localizedDescription)"
                    state.pipelineState = .failed
                    state.overlayTone = .failure
                    resetToReadySoon()
                    return
                }
                guard meetingPipelineToken == token else {
                    MeetingStore.shared.delete(id: preserved.id)
                    return
                }
                guard !Task.isCancelled else {
                    finishMeetingPipeline(token)
                    MeetingStore.shared.delete(id: preserved.id)
                    return
                }
                state.refreshMeetings()
                activePipelineSamples = nil
                clearFailedDictationRetry()
                state.statusMessage = "Meeting transcript saved. Preparing notes…"
                state.pipelineState = .processing

                let note: MeetingNote
                do {
                    note = try await MeetingSummarizer().summarize(
                        transcript: raw,
                        durationSeconds: duration
                    )
                    guard !Task.isCancelled, meetingPipelineToken == token else { return }
                } catch {
                    guard !Task.isCancelled, meetingPipelineToken == token else { return }
                    note = MeetingNote(
                        title: "Meeting transcript",
                        summary:
                            "The on-device summary was unavailable. The complete transcript is preserved.",
                        keyPoints: [],
                        actionItems: []
                    )
                    guard !Task.isCancelled,
                        meetingPipelineToken == token
                    else { return }
                    state.statusMessage =
                        "Meeting saved without a summary. The transcript remains in Meetings."
                    FlowLog.error("meeting summary failed code=\(errorCode: error)")
                }

                let completedNote: MeetingNote
                if captureWasInterrupted {
                    completedNote = MeetingNote(
                        title: note.title,
                        summary:
                            "Recording ended after a microphone interruption; review the transcript ending. "
                            + note.summary,
                        keyPoints: note.keyPoints,
                        actionItems: note.actionItems
                    )
                } else {
                    completedNote = note
                }
                let completed = Meeting(
                    id: preserved.id,
                    createdAt: preserved.createdAt,
                    durationSeconds: duration,
                    rawTranscript: raw,
                    note: completedNote
                )
                do {
                    let updated = try await MeetingStore.shared.update(completed)
                    guard meetingPipelineToken == token else { return }
                    guard !Task.isCancelled else {
                        finishMeetingPipeline(token)
                        return
                    }
                    if !updated {
                        finishMeetingPipeline(token)
                        activePipelineKind = nil
                        state.refreshMeetings()
                        state.statusMessage = "Meeting was deleted before notes finished."
                        state.pipelineState = .done
                        state.overlayTone = .success
                        resetToReadySoon()
                        return
                    }
                } catch {
                    guard !Task.isCancelled, meetingPipelineToken == token else { return }
                    finishMeetingPipeline(token)
                    state.errorMessage =
                        "The transcript is saved, but completed notes could not be saved: \(error.localizedDescription)"
                    state.pipelineState = .failed
                    state.overlayTone = .failure
                    activePipelineKind = nil
                    state.refreshMeetings()
                    resetToReadySoon()
                    return
                }
                guard !Task.isCancelled, meetingPipelineToken == token else { return }
                finishMeetingPipeline(token)
                activePipelineKind = nil
                state.refreshMeetings()
                state.pipelineState = .done
                state.overlayTone = .success
                if captureWasInterrupted {
                    state.statusMessage =
                        "Meeting saved from audio captured before a microphone interruption. Review the ending."
                } else if state.statusMessage == nil
                    || state.statusMessage == "Meeting transcript saved. Preparing notes…"
                {
                    state.statusMessage = "Meeting notes ready."
                }
                WindowOpener.shared.showMeetings(state: state)
            } catch {
                guard !Task.isCancelled, meetingPipelineToken == token else { return }
                finishMeetingPipeline(token)
                if let activeSamples = activePipelineSamples {
                    retainFailedDictationForRetry(
                        activeSamples,
                        state: state,
                        kind: .meeting,
                        captureWasInterrupted: captureWasInterrupted
                    )
                }
                activePipelineSamples = nil
                activePipelineKind = nil
                activeCaptureWasInterrupted = false
                state.errorMessage = "Meeting transcription failed: \(error.localizedDescription)"
                state.pipelineState = .failed
                state.overlayTone = .failure
            }
            if !Task.isCancelled { resetToReadySoon() }
        }
    }

    // MARK: - Floating bar actions

    /// The bar is always toggle semantics, regardless of the hotkey mode:
    /// click mic to start, click stop to transcribe and insert.
    func toggleFromBar() {
        guard let state else { return }
        if state.pipelineState == .recording {
            state.isMeetingRecording ? stopMeeting() : stopAndInsert()
        } else {
            switch state.pipelineState {
            case .idle, .ready, .done, .failed:
                startRecording(requiresHeldHotKey: false)
            default:
                break
            }
        }
    }

    // MARK: - Hotkey entry points

    /// Key-repeat and switch bounce can double-fire an activation — in toggle mode
    /// that reads as "stop mid-sentence." No activation may occur within 700 ms
    /// of the previous one.
    private var lastActivationAt = Date.distantPast

    func hotKeyDown() {
        guard let state else { return }
        let now = Date()
        guard now.timeIntervalSince(lastActivationAt) > 0.7 else { return }
        lastActivationAt = now
        switch state.activationMode {
        case .hold:
            switch state.pipelineState {
            case .idle, .ready, .done, .failed:
                startRecording(requiresHeldHotKey: true)
            default:
                break
            }
        case .toggle:
            if state.pipelineState == .recording {
                state.isMeetingRecording ? stopMeeting() : stopAndInsert()
            } else {
                switch state.pipelineState {
                case .idle, .ready, .done, .failed:
                    startRecording(requiresHeldHotKey: false)
                default:
                    break
                }
            }
        }
    }

    func hotKeyUp() {
        guard let state else { return }
        if captureStartGate.holdTriggerReleased() { return }
        guard state.activationMode == .hold else { return }
        guard state.pipelineState == .recording else { return }
        state.isMeetingRecording ? stopMeeting() : stopAndInsert()
    }

    // MARK: - Recording

    private func startRecording(requiresHeldHotKey: Bool) {
        guard let state,
            !state.isMeetingRecording,
            state.modelReady,
            !captureStartGate.hasPendingAttempt,
            isCaptureStartAllowed(state.pipelineState)
        else { return }
        invalidatePendingReset()
        editWatchToken = nil

        guard
            let token = captureStartGate.begin(
                requiresHeldTrigger: requiresHeldHotKey
            )
        else { return }
        state.errorMessage = nil
        state.statusMessage = nil
        let deliveryMode = state.deliveryMode
        Task {
            defer {
                captureStartGate.finish(token)
            }
            guard captureStartGate.permitsStart(for: token) else { return }
            let microphoneIsAuthorized = await AudioCaptureManager.microphoneAuthorized()
            guard captureStartGate.permitsStart(for: token),
                isCaptureStartAllowed(state.pipelineState)
            else { return }
            guard microphoneIsAuthorized else {
                state.errorMessage = "Microphone permission is required."
                state.microphoneAuthorized = false
                return
            }
            state.microphoneAuthorized = true
            guard state.deliveryMode == deliveryMode else { return }

            if deliveryMode.requiresAccessibility {
                guard TextInserter.isTrusted(prompt: false) else {
                    state.errorMessage =
                        "Automatic insertion needs Accessibility access. Review it in Settings or switch to in-app transcription."
                    state.accessibilityTrusted = false
                    return
                }
                state.accessibilityTrusted = true
            }

            // Automatic typing refuses an explicitly secure target before
            // opening the microphone. In-app transcription never inspects an
            // external field. Delivery still performs full fail-closed validation
            // whenever automatic typing is selected.
            if deliveryMode.requiresAccessibility,
                let focusLock = FrontmostTracker.shared.focusLock(),
                inserter.isExplicitSecureFieldFocused(for: focusLock)
            {
                state.errorMessage =
                    "Passwords and other secure fields must be typed. Recording did not start."
                state.pipelineState = .failed
                state.overlayTone = .failure
                return
            }

            guard captureStartGate.permitsStart(for: token),
                isCaptureStartAllowed(state.pipelineState)
            else { return }

            do {
                try capture.start()
            } catch {
                state.errorMessage = error.localizedDescription
                state.pipelineState = .failed
                return
            }
            // Do not discard a recoverable failure until replacement recording
            // has actually started; denied permissions and start errors leave it
            // available to retry.
            clearFailedDictationRetry()
            captureDeliveryMode = deliveryMode
            heardSpeech = false
            lastLoudAt = .distantPast
            state.updatePipelineMeetingState(false)
            state.pipelineState = .recording
            state.overlayTone = .recording
            state.recordingStartedAt = Date()
            startLevelWatch()
        }
    }

    /// Tracks speech energy for auto-stop (toggle mode). Threshold is deliberately
    /// low — quiet mics and AirPods must never read as silence mid-sentence.
    private func noteLevel(_ level: Float) {
        guard let state, state.pipelineState == .recording else { return }
        if level > 0.025 {
            heardSpeech = true
            lastLoudAt = Date()
        }
    }

    private func startLevelWatch() {
        levelWatchTask?.cancel()
        levelWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let state = self.state, state.pipelineState == .recording else {
                    return
                }
                guard self.keepCaptureHealthy(for: state, isMeeting: false) else { return }

                if self.capture.capturedDuration >= self.maxDictationSeconds {
                    state.statusMessage = "Maximum dictation length reached."
                    self.stopAndInsert()
                    return
                }

                if state.activationMode == .toggle, state.silenceAutoStopSeconds > 0,
                    self.heardSpeech,
                    Date().timeIntervalSince(self.lastLoudAt) > state.silenceAutoStopSeconds
                {
                    self.stopAndInsert()
                    return
                }
            }
        }
    }

    /// Keeps both ordinary dictation and long-running meeting capture from
    /// silently continuing on a dead capture graph. A successful fallback
    /// preserves the samples already captured; a failed rebuild ends the active
    /// recording and leaves the UI in a truthful, actionable state.
    private func keepCaptureHealthy(for state: AppState, isMeeting: Bool) -> Bool {
        do {
            if try capture.recoverCaptureIfNeeded() {
                if !isMeeting {
                    heardSpeech = false
                    lastLoudAt = .distantPast
                }
                state.level = 0
                state.statusMessage = "Microphone recovered — using standard input."
            }
            return true
        } catch {
            let stopped = capture.stopWithResult()
            let terminalError =
                stopped.terminalError
                ?? (error as? AudioCaptureError)
                ?? .engineFailed(error.localizedDescription)
            let result = AudioCaptureStopResult(
                samples: stopped.samples,
                terminalError: terminalError
            )
            if isMeeting {
                stopMeeting(captureResult: result)
            } else {
                stopAndInsert(captureResult: result)
            }
            return false
        }
    }

    /// Returns preserved samples after an interrupted graph, or transitions to
    /// failure when the stopped attempt contains no usable audio. This same
    /// decision is used by the health poll and a manual stop racing the poll.
    private func usableSamples(
        from result: AudioCaptureStopResult,
        state: AppState,
        isMeeting: Bool
    ) -> UsableCapture? {
        guard let error = result.terminalError else {
            return UsableCapture(samples: result.samples, wasInterrupted: false)
        }

        FlowLog.error(
            "capture ended after microphone restart failure code=\(errorCode: error)"
        )
        guard !result.samples.isEmpty,
            !AudioCaptureManager.isSilentCapture(result.samples)
        else {
            state.level = 0
            state.recordingStartedAt = nil
            if isMeeting { state.isMeetingRecording = false }
            state.errorMessage =
                "Microphone recovery failed before usable audio was captured: \(error.localizedDescription)"
            state.pipelineState = .failed
            state.overlayTone = .failure
            return nil
        }

        state.statusMessage = "Microphone changed — processing the audio captured so far."
        return UsableCapture(samples: result.samples, wasInterrupted: true)
    }

    private func stopAndInsert(captureResult: AudioCaptureStopResult? = nil) {
        guard let state else { return }
        levelWatchTask?.cancel()
        let result = captureResult ?? capture.stopWithResult()
        // Freeze the destination application and its formatting profile from a
        // single synchronized snapshot at the user's stop boundary. The exact
        // field remains intentionally unresolved until delivery.
        let targetSnapshot =
            captureDeliveryMode.requiresAccessibility
            ? FrontmostTracker.shared.targetSnapshot(profileOverrideID: state.profileOverrideID)
            : nil
        if let focusLock = targetSnapshot?.focusLock,
            inserter.isExplicitSecureFieldFocused(for: focusLock)
        {
            state.level = 0
            state.recordingStartedAt = nil
            state.errorMessage =
                "Dictation was discarded because a secure field was focused when recording ended."
            state.pipelineState = .failed
            state.overlayTone = .failure
            return
        }
        guard
            let capture = usableSamples(
                from: result,
                state: state,
                isMeeting: false
            )
        else { return }

        let context = DictationContext(
            targetSnapshot: targetSnapshot,
            localProfile: state.effectiveProfile,
            deliveryMode: captureDeliveryMode,
            captureWasInterrupted: capture.wasInterrupted
        )

        state.statusMessage =
            context.deliveryMode.requiresAccessibility
            ? "Processing locally — keep the destination field focused until insertion finishes."
            : "Transcribing locally — your text will appear in LockedIn Flow."
        processAndInsert(capture.samples, context: context)
    }

    /// Runs already-captured samples through the normal pipeline. Keeping this
    /// separate from capture lets a failed transcription or cleanup attempt be
    /// retried without recording again or ever writing raw audio to disk.
    private func processAndInsert(
        _ samples: [Float],
        context: DictationContext
    ) {
        guard let state else { return }
        invalidatePendingReset()
        meetingPipelineToken = nil
        state.updatePipelineMeetingState(false)
        activePipelineSamples = samples
        activePipelineKind = .dictation
        activeDictationContext = context
        activeCaptureWasInterrupted = context.captureWasInterrupted
        let audioDuration = Double(samples.count) / AudioCaptureManager.targetSampleRate
        state.level = 0
        state.recordingStartedAt = nil
        // Long dictations legitimately need long processing — scale the watchdog
        // leash to the audio length instead of cutting off at a flat 45 s.
        state.processingBudgetSeconds = max(60, 30 + audioDuration * 0.5)
        state.pipelineState = .transcribing
        state.overlayTone = .working

        pipelineTask = Task {
            defer { activeCaptureWasInterrupted = false }
            do {
                let preparedAudio = await audioPreparer.prepare(
                    samples,
                    enabled: state.voiceActivityFilteringEnabled
                )
                guard !Task.isCancelled else { return }
                guard let transcriptionSamples = preparedAudio.samplesForTranscription else {
                    reportNoSpeech(state, samples: samples, context: context)
                    return
                }

                let raw = try await stt.transcribe(transcriptionSamples)
                guard !Task.isCancelled else { return }
                guard !raw.isEmpty else {
                    reportNoSpeech(state, samples: samples, context: context)
                    return
                }

                if context.deliveryMode.requiresAccessibility,
                    let command = commandParser.command(for: raw)
                {
                    activePipelineSamples = nil
                    activePipelineKind = nil
                    activeDictationContext = nil
                    clearFailedDictationRetry()
                    await handle(command, context: context)
                    return
                }

                var final = raw
                if state.cleanupEnabled {
                    state.pipelineState = .processing
                    if state.llmCleanupEnabled, LLMCleaner.isLLMAvailable {
                        let llm = LLMCleaner(
                            interpretSpokenPunctuation: state.spokenPunctuation,
                            vocabularyHints: vocabulary.writtenHints(for: context.profile.id)
                        )
                        final = try await llm.clean(raw, profile: context.profile)
                    } else {
                        let cleaner = RulesCleaner(
                            interpretSpokenPunctuation: state.spokenPunctuation)
                        final = try await cleaner.clean(raw, profile: context.profile)
                    }
                }
                guard !Task.isCancelled else { return }
                let vocabularySnapshot = vocabulary
                let profileID = context.profile.id
                let textBeforeVocabulary = final
                final = await Task.detached(priority: .userInitiated) {
                    vocabularySnapshot.apply(to: textBeforeVocabulary, profileID: profileID)
                }.value
                guard !Task.isCancelled else { return }
                if let expansion = snippets.expansion(for: final) {
                    final = expansion
                }
                if state.translationTarget != .off, LLMTranslator.isAvailable {
                    do {
                        let translated = try await LLMTranslator().translate(
                            final,
                            to: state.translationTarget
                        )
                        if !translated.isEmpty { final = translated }
                    } catch {
                        guard !Task.isCancelled else { return }
                        // Translation is an enhancement; inserting the original
                        // transcript is always safer than losing the dictation.
                        FlowLog.error("translation failed code=\(errorCode: error)")
                        state.statusMessage =
                            "Translation unavailable — kept the original transcript."
                    }
                }
                guard !Task.isCancelled else { return }
                // Transcription and processing completed. Insertion has its own
                // text recovery path, so raw audio is no longer needed.
                activePipelineSamples = nil
                activePipelineKind = nil
                clearFailedDictationRetry()

                // Keep the completed transcript in this task until the final
                // secure-target check has passed. Ordinary delivery failures are
                // persisted and copied below, but a late secure-field race must
                // never write the transcript to History, Recovery, or pasteboard.
                guard !Task.isCancelled else { return }
                if context.deliveryMode == .inApp {
                    completeInAppTranscription(
                        raw: raw, final: final, duration: audioDuration,
                        context: context, state: state)
                    resetToReadySoon()
                    return
                }
                await completeInsertion(
                    raw: raw,
                    final: final,
                    duration: audioDuration,
                    context: context,
                    state: state
                )
            } catch {
                if !Task.isCancelled {
                    FlowLog.error("dictation pipeline failed code=\(errorCode: error)")
                    retainFailedDictationForRetry(
                        samples,
                        state: state,
                        context: context
                    )
                    activePipelineSamples = nil
                    activePipelineKind = nil
                    activeDictationContext = nil
                    state.errorMessage = error.localizedDescription
                    state.pipelineState = .failed
                    state.overlayTone = .failure
                }
            }
            if !Task.isCancelled { resetToReadySoon() }
        }
    }

    private func completeInAppTranscription(
        raw: String, final: String, duration: TimeInterval,
        context: DictationContext, state: AppState
    ) {
        state.lastRaw = raw
        state.lastFinal = final
        let outcome =
            context.captureWasInterrupted ? "transcribed:local:partial-audio" : "transcribed:local"
        recordHistory(
            raw: raw, final: final, duration: duration, appName: nil,
            profile: context.profile, state: state, outcome: outcome)
        state.wordsThisSession += final.split(separator: " ").count
        state.pipelineState = .done
        state.overlayTone = .success
        state.statusMessage =
            context.captureWasInterrupted
            ? "Microphone interrupted. The captured portion is in LockedIn Flow; review the ending before copying."
            : "Transcript ready in LockedIn Flow. Choose Copy when you want to use it elsewhere."
        activeDictationContext = nil
        activeCaptureWasInterrupted = false
        state.showHomeWindow()
    }

    private func recordHistory(
        raw: String,
        final: String,
        duration: TimeInterval,
        appName: String?,
        profile: AppProfile,
        state: AppState,
        outcome: String
    ) {
        let entry = HistoryEntry(
            raw: raw,
            final: final,
            duration: duration,
            profileID: profile.id,
            targetAppName: appName,
            modelID: stt.modelID + " · " + outcome
        )
        HistoryStore.shared.record(entry)
        StatsStore.shared.record(words: final.split(separator: " ").count, seconds: duration)
        state.refreshHistory()
        state.refreshStats()
    }

    private func recordContentFreeStats(final: String, duration: TimeInterval, state: AppState) {
        StatsStore.shared.record(words: final.split(separator: " ").count, seconds: duration)
        state.refreshStats()
    }

    private func handle(_ command: SpokenCommand, context: DictationContext) async {
        guard let state else { return }
        switch command {
        case .cancel:
            state.statusMessage = "Dictation discarded."
            state.pipelineState = .ready
        case .undoLast, .deleteLastSentence:
            do {
                guard let focusLock = context.focusLock else {
                    throw InsertionError.noTargetApplication
                }
                // A spoken command may finish while the activating Home window
                // is frontmost. Use the same bounded, secure target preparation
                // as ordinary delivery before posting the command keystroke.
                _ = try await inserter.prepareTargetForOrdinaryCapture(focusLock)
                try inserter.postUndoKeystroke(into: focusLock)
                state.statusMessage =
                    command == .undoLast
                    ? "Undid last insertion."
                    : "Deleted last sentence."
                state.pipelineState = .done
                state.overlayTone = .success
            } catch {
                state.errorMessage = Self.commandFailureMessage(for: error)
                state.pipelineState = .failed
                state.overlayTone = .failure
            }
        }
        resetToReadySoon()
    }

    func reinsertLast() {
        guard let state else { return }
        guard state.automaticInsertionEnabled else {
            state.errorMessage = "Automatic insertion is off. Use Copy or enable it in Settings."
            return
        }
        guard state.pendingReinsertInspection == nil,
            !reinsertTaskGate.hasPendingInspection
        else {
            state.statusMessage = nil
            return
        }
        guard isCaptureStartAllowed(state.pipelineState) else {
            state.errorMessage =
                "Wait for the current recording or insertion to finish before re-inserting."
            return
        }
        guard !state.lastFinal.isEmpty else { return }
        guard let focusLock = FrontmostTracker.shared.focusLock() else {
            state.errorMessage = InsertionError.noTargetApplication.localizedDescription
            return
        }
        let raw = state.lastRaw
        let final = state.lastFinal
        guard let lease = reinsertTaskGate.begin() else {
            state.errorMessage = "Wait for the current re-insertion to finish."
            return
        }
        state.pipelineState = .inserting
        let task = Task { [weak self] in
            guard let self else { return }
            var reportsPreEventCancellation = false
            var inspectionMessage: String?
            defer {
                let stillOwnsTask = reinsertTaskGate.permitsEffects(for: lease)
                let inspection = reinsertTaskGate.finish(
                    lease,
                    requiringInspection: stillOwnsTask && inspectionMessage != nil
                )
                if stillOwnsTask, state.pipelineState == .inserting {
                    state.pipelineState = state.modelReady ? .ready : .preparing
                }
                if let inspection, let inspectionMessage {
                    state.presentReinsertInspection(
                        ReinsertInspectionNotice(
                            inspection: inspection,
                            sourceID: nil,
                            message: inspectionMessage
                        )
                    )
                }
                if stillOwnsTask, reportsPreEventCancellation {
                    state.errorMessage = nil
                    state.statusMessage = "Re-insertion canceled."
                }
            }
            do {
                try requireCurrentReinsert(lease)
                var target =
                    try await inserter
                    .prepareTargetForOrdinaryCapture(
                        focusLock
                    )
                try requireCurrentReinsert(lease)
                target =
                    try await inserter
                    .restoreFocusForOrdinaryDictation(to: target)
                try requireCurrentReinsert(lease)
                let result = try await inserter.insertOrdinary(
                    final,
                    into: target,
                    commitDelivery: { [self] in
                        guard self.reinsertTaskGate.commitDelivery(lease) else {
                            throw CancellationError()
                        }
                    }
                )
                guard !Task.isCancelled,
                    !reinsertTaskGate.cancellationRequested(for: lease),
                    reinsertTaskGate.permitsEffects(for: lease)
                else {
                    state.errorMessage = nil
                    inspectionMessage =
                        Self
                        .confirmedDeliveryCancellationSafetyNotice(for: result)
                    return
                }
                try requireCurrentReinsert(lease)
                RecoveryStore.shared.record(
                    raw: raw, final: final,
                    targetAppName: focusLock.appName,
                    status: "reinserted")
                try requireCurrentReinsert(lease)
                if result.clipboardDisposition
                    == .pasteTransportRestorationUnverified
                {
                    inspectionMessage =
                        "Re-inserted. Check the clipboard before continuing because its final state could not be verified."
                } else {
                    state.statusMessage = "Re-inserted."
                }
            } catch {
                let safetyNotice = Self.cancellationSafetyNotice(for: error)
                let cancellationRequested =
                    reinsertTaskGate
                    .cancellationRequested(for: lease)
                // A stale task never owns global UI state. Phase-aware cancel
                // retains the active lease until this task terminates, so any
                // legitimate safety notice is published while ownership is
                // still current.
                guard reinsertTaskGate.permitsEffects(for: lease) else { return }
                if let insertion = error as? InsertionError,
                    insertion.requiresReinsertInspection
                {
                    inspectionMessage =
                        cancellationRequested
                        ? safetyNotice ?? Self.reinsertFailureMessage(for: error)
                        : Self.reinsertFailureMessage(for: error)
                    return
                }
                if cancellationRequested || error is CancellationError {
                    reportsPreEventCancellation = true
                    return
                }
                state.errorMessage = Self.reinsertFailureMessage(for: error)
            }
        }
        reinsertTaskGate.attach(task, to: lease)
    }

    func reinsert(
        _ text: String,
        sourceID: UUID? = nil,
        completion: @escaping (Result<ReinsertSuccess, Error>) -> Void
    ) {
        guard let state else {
            completion(.failure(InsertionError.noTargetApplication))
            return
        }
        guard state.automaticInsertionEnabled else {
            completion(.failure(InsertionError.accessibilityNotTrusted))
            return
        }
        if let notice = state.pendingReinsertInspection {
            completion(.failure(ReinsertSafetyNoticeError(notice: notice)))
            return
        }
        guard !reinsertTaskGate.hasPendingInspection else {
            completion(.failure(InsertionError.insertionRejected))
            return
        }
        guard isCaptureStartAllowed(state.pipelineState) else {
            let error = InsertionError.insertionRejected
            state.errorMessage =
                "Wait for the current recording or insertion to finish before re-inserting."
            completion(.failure(error))
            return
        }
        guard let focusLock = FrontmostTracker.shared.focusLock() else {
            state.errorMessage = InsertionError.noTargetApplication.localizedDescription
            completion(.failure(InsertionError.noTargetApplication))
            return
        }
        let appName = focusLock.appName ?? "the focused app"
        guard let lease = reinsertTaskGate.begin() else {
            let error = InsertionError.insertionRejected
            state.errorMessage = "Wait for the current re-insertion to finish."
            completion(.failure(error))
            return
        }
        state.pipelineState = .inserting
        let task = Task { [weak self] in
            guard let self else { return }
            var terminalResult: Result<ReinsertSuccess, Error>?
            var inspectionMessage: String?
            defer {
                let stillOwnsTask = reinsertTaskGate.permitsEffects(for: lease)
                let inspection = reinsertTaskGate.finish(
                    lease,
                    requiringInspection: stillOwnsTask && inspectionMessage != nil
                )
                if stillOwnsTask, state.pipelineState == .inserting {
                    state.pipelineState = state.modelReady ? .ready : .preparing
                }
                // Release the old lease and settle its pipeline state before
                // invoking external UI code. A re-entrant completion may begin
                // a new task, which the old task must never reset afterward.
                if let inspection, let inspectionMessage {
                    let notice = ReinsertInspectionNotice(
                        inspection: inspection,
                        sourceID: sourceID,
                        message: inspectionMessage
                    )
                    state.presentReinsertInspection(notice)
                    if let terminalResult {
                        completion(terminalResult)
                    } else {
                        completion(.failure(ReinsertSafetyNoticeError(notice: notice)))
                    }
                } else if stillOwnsTask, let terminalResult {
                    completion(terminalResult)
                }
            }
            do {
                try requireCurrentReinsert(lease)
                var target =
                    try await inserter
                    .prepareTargetForOrdinaryCapture(
                        focusLock
                    )
                try requireCurrentReinsert(lease)
                target =
                    try await inserter
                    .restoreFocusForOrdinaryDictation(to: target)
                try requireCurrentReinsert(lease)
                let result = try await inserter.insertOrdinary(
                    text,
                    into: target,
                    commitDelivery: { [self] in
                        guard self.reinsertTaskGate.commitDelivery(lease) else {
                            throw CancellationError()
                        }
                    }
                )
                guard !Task.isCancelled,
                    !reinsertTaskGate.cancellationRequested(for: lease),
                    reinsertTaskGate.permitsEffects(for: lease)
                else {
                    let outcome = ReinsertSuccess(
                        appName: appName,
                        requiresClipboardInspection: result.clipboardDisposition
                            == .pasteTransportRestorationUnverified,
                        completedBeforeCancellation: true
                    )
                    state.errorMessage = nil
                    inspectionMessage = outcome.statusMessage
                    terminalResult = .success(outcome)
                    return
                }
                let outcome = ReinsertSuccess(
                    appName: appName,
                    requiresClipboardInspection: result.clipboardDisposition
                        == .pasteTransportRestorationUnverified
                )
                if outcome.requiresInspectionAcknowledgement {
                    inspectionMessage = outcome.statusMessage
                } else {
                    state.statusMessage = outcome.statusMessage
                }
                terminalResult = .success(outcome)
            } catch {
                let safetyNotice = Self.cancellationSafetyNotice(for: error)
                let cancellationRequested =
                    reinsertTaskGate
                    .cancellationRequested(for: lease)
                // Completion ownership is token-bound; stale work must never
                // overwrite a replacement task, even with a safety message.
                guard reinsertTaskGate.permitsEffects(for: lease) else { return }
                if let insertion = error as? InsertionError,
                    insertion.requiresReinsertInspection
                {
                    inspectionMessage =
                        cancellationRequested
                        ? safetyNotice ?? Self.reinsertFailureMessage(for: error)
                        : Self.reinsertFailureMessage(for: error)
                    return
                }
                if cancellationRequested || error is CancellationError {
                    state.errorMessage = nil
                    state.statusMessage = "Re-insertion canceled."
                    terminalResult = .failure(CancellationError())
                    return
                }
                state.errorMessage = Self.reinsertFailureMessage(for: error)
                terminalResult = .failure(error)
            }
        }
        reinsertTaskGate.attach(task, to: lease)
    }

    /// User acknowledgment only clears the exact terminal inspection latch.
    /// It never captures focus, stages the clipboard, or starts an insertion.
    func acknowledgeReinsertInspection(_ notice: ReinsertInspectionNotice) {
        guard state?.pendingReinsertInspection == notice else { return }
        guard reinsertTaskGate.acknowledgeInspection(notice.inspection) else {
            return
        }
        state?.clearReinsertInspection(notice)
    }

    func cancel() {
        invalidatePendingReset()
        captureStartGate.cancelAll()
        meetingPipelineToken = nil
        pipelineTask?.cancel()
        let reinsertCancellationPending = reinsertTaskGate.cancelAll()
        levelWatchTask?.cancel()
        capture.cancel()
        activePipelineSamples = nil
        activePipelineKind = nil
        activeDictationContext = nil
        activeCaptureWasInterrupted = false
        clearFailedDictationRetry()
        state?.isMeetingRecording = false
        state?.updatePipelineMeetingState(false)
        state?.level = 0
        state?.recordingStartedAt = nil
        if reinsertCancellationPending {
            // Keep both the busy state and the gate lease until the cancelled
            // task establishes whether Cmd+V had already been dispatched.
            // Pre-event cancellation resolves promptly; post-event receipt
            // remains non-retryable until its terminal inspection outcome.
            state?.statusMessage = "Canceling re-insertion…"
            state?.pipelineState = .inserting
        } else {
            state?.pipelineState = .ready
        }
    }

    /// Re-runs the most recent failed dictation or meeting in this app session.
    /// The samples are removed from the public retry state while the attempt is
    /// active and retained again only if transcription or processing fails.
    func retryFailedDictation() {
        guard let state,
            state.modelReady,
            !captureStartGate.hasPendingAttempt
        else { return }
        switch state.pipelineState {
        case .idle, .ready, .failed:
            break
        case .preparing, .recording, .transcribing, .processing, .inserting, .done:
            return
        }
        guard let samples = retryBuffer.recordingForRetry() else { return }
        let kind = retryKind
        let context = retryDictationContext
        let meetingCaptureWasInterrupted = retryMeetingCaptureWasInterrupted
        invalidatePendingReset()
        clearFailedDictationRetry()
        state.errorMessage = nil
        switch kind {
        case .dictation:
            state.statusMessage = "Retrying dictation…"
            let retryContext =
                context
                ?? DictationContext(
                    targetSnapshot: nil,
                    localProfile: state.effectiveProfile,
                    deliveryMode: .inApp,
                    captureWasInterrupted: false
                )
            processAndInsert(
                samples,
                context: retryContext
            )
        case .meeting:
            state.statusMessage = "Retrying meeting transcription…"
            processMeeting(
                samples,
                captureWasInterrupted: meetingCaptureWasInterrupted
            )
        }
    }

    /// Explicitly forgets the session-only failed recording.
    func discardFailedDictation() {
        guard retryBuffer.hasRecording else { return }
        clearFailedDictationRetry()
        state?.errorMessage = nil
        state?.statusMessage = "Failed recording discarded."
    }

    // MARK: - Helpers

    private func requireCurrentReinsert(
        _ lease: ReinsertTaskGate.Lease
    ) throws {
        try Task.checkCancellation()
        guard reinsertTaskGate.permitsEffects(for: lease) else {
            throw CancellationError()
        }
    }

    private static func cancellationSafetyNotice(
        for error: Error
    ) -> String? {
        guard let insertion = error as? InsertionError,
            insertion.requiresCancellationSafetyNotice
        else { return nil }
        switch insertion {
        case .clipboardRestorationUnverified:
            return
                "Cancellation completed before a paste command was sent. Inspect the clipboard before continuing because restoration of its prior contents could not be verified."
        case .sensitiveClipboardRestorationUnverifiedBeforeInsertion:
            return
                "Cancellation completed before a paste command was sent. Clear or inspect the clipboard before continuing because removal of the staged transcript could not be verified."
        case .insertionAndClipboardRestorationUnverified,
            .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan:
            return
                "Cancellation completed after delivery began. Inspect the original field and clipboard before continuing; no second paste was sent."
        case .clipboardChangedAfterInsertionBegan:
            return
                "Cancellation completed after delivery began. Inspect the original field before continuing; no second paste was sent and the newer clipboard was preserved."
        case .insertionUnverified,
            .accessibilityInsertionUnverifiedPreservingClipboard,
            .sensitiveInsertionUnverified:
            return
                "Cancellation completed after delivery began. Inspect the original field before continuing; no second insertion was attempted."
        default:
            return nil
        }
    }

    private static func confirmedDeliveryCancellationSafetyNotice(
        for result: InsertionResult
    ) -> String {
        if result.clipboardDisposition
            == .pasteTransportRestorationUnverified
        {
            return
                "Insertion completed before cancellation. Inspect the original field and clipboard before continuing; do not retry the insertion."
        }
        return
            "Insertion completed before cancellation. Inspect the original field before continuing; do not retry the insertion."
    }

    private static func reinsertFailureMessage(for error: Error) -> String {
        if let insertion = error as? InsertionError {
            switch insertion {
            case .sensitiveClipboardRestorationUnverifiedBeforeInsertion:
                return
                    "Clear or inspect the clipboard before continuing. No paste command was sent, but removal of the staged transcript could not be verified. The original transcript remains in LockedIn Flow."
            case .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan:
                return
                    "Inspect the original field and clear or inspect the clipboard before continuing. Delivery and staged-transcript removal could not be verified; the original transcript remains in LockedIn Flow."
            default:
                break
            }
            if let preservation = insertion.clipboardPreservationUserMessage {
                return preservation
            }
            switch insertion {
            case .secureField, .targetSecurityUnverifiable,
                .sensitiveInsertionUnverified:
                return insertion.localizedDescription
            case .insertionUnverified,
                .accessibilityInsertionUnverifiedPreservingClipboard:
                return
                    "Check the original field before retrying. Re-insertion could not be verified, and no second paste was sent. The transcript remains in LockedIn Flow."
            default:
                break
            }
        }
        return
            "Re-insertion stopped. The transcript remains in LockedIn Flow and the clipboard was not replaced."
    }

    /// Insertion can fail for reasons the user can act on and reasons they
    /// cannot. Only the first kind is worth spending their attention on.
    static func insertionFailureMessage(
        for error: Error,
        clipboardWriteOutcome: PasteboardWriteOutcome? = nil
    ) -> String {
        guard let insertion = error as? InsertionError else {
            switch clipboardWriteOutcome {
            case .written:
                return "Insertion failed — transcript copied to clipboard."
            case .newerContentPreserved:
                return
                    "Insertion failed. The clipboard was not replaced; the transcript remains in LockedIn Flow for retry."
            case .originalContentsRestored:
                return
                    "Insertion failed. The prior clipboard was restored; the transcript remains in LockedIn Flow for retry."
            case .clipboardUnchanged:
                return
                    "Insertion failed. The clipboard was left unchanged; the transcript remains in LockedIn Flow for retry."
            case .outcomeUnverified:
                return
                    "Insertion failed. Check the clipboard because its final state could not be verified; the transcript remains in LockedIn Flow."
            case .none:
                return
                    "Insertion failed. The transcript remains in LockedIn Flow for retry; the clipboard was not replaced."
            }
        }
        if let message = insertion.clipboardPreservationUserMessage {
            return message
        }
        if !insertion.requiresSensitiveContentDiscard,
            let clipboardWriteOutcome,
            clipboardWriteOutcome != .written
        {
            let fieldPrefix =
                insertion == .insertionUnverified
                    || insertion == .accessibilityInsertionUnverifiedPreservingClipboard
                ? "Check the original field before continuing. The insertion could not be verified. "
                : "Insertion failed. "
            switch clipboardWriteOutcome {
            case .newerContentPreserved:
                // A generic generation mismatch can be our own staging and
                // restoration, so do not speculate that the contents are newer.
                return fieldPrefix
                    + "The clipboard was not replaced; the transcript remains in LockedIn Flow for retry."
            case .originalContentsRestored:
                return fieldPrefix
                    + "The prior clipboard was restored; the transcript remains in LockedIn Flow for retry."
            case .clipboardUnchanged:
                return fieldPrefix
                    + "The clipboard was left unchanged; the transcript remains in LockedIn Flow for retry."
            case .outcomeUnverified:
                return fieldPrefix
                    + "Check the clipboard because its final state could not be verified; the transcript remains in LockedIn Flow."
            case .written:
                break
            }
        }
        switch insertion {
        case .accessibilityNotTrusted:
            return "Accessibility permission is needed to insert text. "
                + "Enable LockedIn Flow in System Settings → Privacy & Security → Accessibility, "
                + "then relaunch. Your transcript is on the clipboard."
        case .secureField:
            return "That is a secure field, so nothing was inserted or saved. "
                + "Type passwords and verification codes directly."
        case .targetSecurityUnverifiable:
            return "LockedIn Flow could not verify that field was non-secure, "
                + "so nothing was inserted, copied, or saved."
        case .sensitiveInsertionUnverified:
            return "Check the original field before continuing. "
                + "LockedIn Flow sent the paste command but could not verify where the text landed; "
                + "nothing was copied or saved."
        case .sensitiveClipboardRestorationUnverifiedBeforeInsertion,
            .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan:
            return insertion.clipboardPreservationUserMessage!
        // Every message below leads with the recovery action: the bar is narrow
        // and truncates, so the actionable half must come first.
        case .focusChanged:
            return "Copied — press ⌘V to paste. "
                + "Focus moved to another app before the text could be inserted."
        case .targetFieldChanged:
            return "Copied — press ⌘V to paste. "
                + "The text field changed before the text could be inserted."
        case .noTargetApplication:
            return "Copied — press ⌘V to paste. No app was focused for insertion."
        case .insertionRejected:
            return "Copied — press ⌘V to paste. That app didn't accept the text directly."
        case .insertionUnverified:
            return "Copied — check the field, then press ⌘V if the text is missing. "
                + "LockedIn Flow couldn't confirm that app accepted it."
        case .accessibilityInsertionUnverifiedPreservingClipboard:
            return insertion.clipboardPreservationUserMessage!
        case .clipboardRestorationUnverified:
            return insertion.clipboardPreservationUserMessage!
        case .insertionAndClipboardRestorationUnverified:
            return insertion.clipboardPreservationUserMessage!
        case .clipboardChangedBeforeInsertion:
            return insertion.clipboardPreservationUserMessage!
        case .clipboardChangedAfterInsertionBegan:
            return insertion.clipboardPreservationUserMessage!
        }
    }

    private static func commandFailureMessage(for error: Error) -> String {
        switch error as? InsertionError {
        case .accessibilityNotTrusted:
            return "Accessibility permission is needed before an undo command can be sent."
        case .secureField:
            return "Undo commands are blocked while a password field is focused."
        case .targetSecurityUnverifiable, .sensitiveInsertionUnverified,
            .sensitiveClipboardRestorationUnverifiedBeforeInsertion,
            .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan:
            return
                "LockedIn Flow could not verify that field was non-secure, so the undo command was not sent."
        case .focusChanged, .targetFieldChanged:
            return "Focus moved to another app, so the undo command was not sent."
        case .noTargetApplication:
            return "No target app was available, so the undo command was not sent."
        case .insertionRejected, .insertionUnverified,
            .accessibilityInsertionUnverifiedPreservingClipboard,
            .clipboardRestorationUnverified,
            .insertionAndClipboardRestorationUnverified,
            .clipboardChangedBeforeInsertion,
            .clipboardChangedAfterInsertionBegan, .none:
            return "LockedIn Flow could not safely send the undo command."
        }
    }

    private func reportNoSpeech(
        _ state: AppState,
        samples: [Float],
        context: DictationContext
    ) {
        activePipelineSamples = nil
        activePipelineKind = nil
        activeDictationContext = nil
        if AudioCaptureManager.isSilentCapture(samples) {
            clearFailedDictationRetry()
            FlowLog.info("dictation completed with no signal from the input device")
            state.errorMessage =
                "No audio reached the microphone. "
                + "Check Sound input, close other dictation or meeting apps, then try again."
        } else {
            retainFailedDictationForRetry(
                samples,
                state: state,
                context: context
            )
            FlowLog.info("dictation completed without recognized speech")
            state.errorMessage = "No speech heard — try again."
        }
        state.statusMessage = nil
        state.pipelineState = .failed
        state.overlayTone = .failure
        resetToReadySoon()
    }

    private func retainFailedDictationForRetry(
        _ samples: [Float],
        state: AppState,
        kind: RetryKind = .dictation,
        context: DictationContext? = nil,
        captureWasInterrupted: Bool = false
    ) {
        guard retryBuffer.retain(samples) else { return }
        retryKind = kind
        retryDictationContext = kind == .dictation ? context : nil
        retryMeetingCaptureWasInterrupted =
            kind == .meeting ? captureWasInterrupted : false
        state.updateFailedDictationRetryAvailability(true, isMeeting: kind == .meeting)
    }

    private func clearFailedDictationRetry() {
        retryBuffer.discard()
        retryKind = .dictation
        retryDictationContext = nil
        retryMeetingCaptureWasInterrupted = false
        state?.updateFailedDictationRetryAvailability(false)
    }

    private func finishMeetingPipeline(_ token: UUID) {
        if meetingPipelineToken == token {
            meetingPipelineToken = nil
        }
    }

    /// Automatic timeout recovery is intentionally non-destructive. Unlike an
    /// explicit user cancel, it preserves a usable in-flight recording for one
    /// more local transcription attempt.
    func recoverFromProcessingTimeout() {
        guard let state else { return }
        invalidatePendingReset()
        if reinsertTaskGate.cancelAll() {
            // Re-insertion has its own phase-aware timeout path. Retain its
            // lease and busy state until the exact delivery result settles;
            // the generic pipeline watchdog must not expose an early retry.
            state.statusMessage = "Canceling stalled re-insertion…"
            state.pipelineState = .inserting
            return
        }
        captureStartGate.cancelAll()
        meetingPipelineToken = nil
        pipelineTask?.cancel()
        levelWatchTask?.cancel()
        capture.cancel()

        let timedOutKind = activePipelineKind ?? .dictation
        let timedOutContext = activeDictationContext
        let timedOutCaptureWasInterrupted = activeCaptureWasInterrupted
        if let samples = activePipelineSamples,
            !samples.isEmpty,
            !AudioCaptureManager.isSilentCapture(samples)
        {
            retainFailedDictationForRetry(
                samples,
                state: state,
                kind: timedOutKind,
                context: timedOutContext,
                captureWasInterrupted: timedOutCaptureWasInterrupted
            )
            state.errorMessage =
                timedOutKind == .meeting
                ? "Meeting transcription took too long. The recording is still available to retry."
                : "Dictation took too long. Your recording is still available to retry."
        } else if timedOutKind == .meeting {
            state.errorMessage =
                "Meeting notes took too long. The encrypted transcript is saved in Meetings."
        } else {
            state.errorMessage = "Recovered from a stalled dictation."
        }
        activePipelineSamples = nil
        activePipelineKind = nil
        activeDictationContext = nil
        activeCaptureWasInterrupted = false
        state.level = 0
        state.recordingStartedAt = nil
        state.pipelineState = .failed
        state.overlayTone = .failure
    }

    private func isCaptureStartAllowed(_ pipelineState: PipelineState) -> Bool {
        switch pipelineState {
        case .idle, .ready, .done, .failed:
            return true
        case .preparing, .recording, .transcribing, .processing, .inserting:
            return false
        }
    }

    private func resetToReadySoon() {
        let token = UUID()
        resetToken = token
        Task {
            // Success flashes by; a failure must stay on screen long enough to read.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard resetToken == token,
                let state,
                state.pipelineState == .done
            else { return }
            resetToken = nil
            state.pipelineState = state.modelReady ? .ready : .preparing
            state.updatePipelineMeetingState(false)
        }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard resetToken == token,
                let state,
                state.pipelineState == .failed
            else { return }
            resetToken = nil
            state.pipelineState = state.modelReady ? .ready : .preparing
            state.updatePipelineMeetingState(false)
        }
    }

    private func invalidatePendingReset() {
        resetToken = nil
    }
}
