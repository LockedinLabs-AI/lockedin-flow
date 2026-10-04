import AVFoundation
import VoiceCore

public enum AudioCaptureError: Error, LocalizedError, Sendable, Equatable {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access was denied."
        case .noInputDevice: return "No audio input device is available."
        case .converterUnavailable: return "Could not create the audio format converter."
        case .engineFailed(let detail): return "Audio engine failed: \(detail)"
        }
    }
}

/// Controls whether capture should make a best-effort attempt to use Apple's
/// system voice-processing path. Automatic mode always falls back to the raw
/// microphone path when the current audio device doesn't support it.
public enum VoiceProcessingPreference: Sendable, Equatable {
    case automatic
    case disabled
}

enum VoiceProcessingActivation: Equatable {
    case enabled
    case disabledByPreference
    case unavailable
}

protocol VoiceProcessingConfiguring: AnyObject {
    var isVoiceProcessingEnabled: Bool { get }
    var isVoiceProcessingBypassed: Bool { get set }
    var isVoiceProcessingAGCEnabled: Bool { get set }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws
}

extension AVAudioInputNode: VoiceProcessingConfiguring {}

enum VoiceProcessingConfigurator {
    static func activate(
        on input: any VoiceProcessingConfiguring,
        preference: VoiceProcessingPreference
    ) -> VoiceProcessingActivation {
        guard preference == .automatic else {
            return .disabledByPreference
        }

        do {
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled else {
                return .unavailable
            }

            // Apple's voice-processing unit provides the microphone uplink
            // processing. Keep it engaged and retain its default AGC so quiet
            // speakers aren't lost. No additional spectral gate or hard noise
            // threshold is applied to the captured samples.
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = true
            return input.isVoiceProcessingBypassed ? .unavailable : .enabled
        } catch {
            return .unavailable
        }
    }
}

enum VoiceProcessingAttemptPlan {
    static func preferences(for preference: VoiceProcessingPreference)
        -> [VoiceProcessingPreference]
    {
        switch preference {
        case .automatic: return [.automatic, .disabled]
        case .disabled: return [.disabled]
        }
    }
}

/// Resolves the user-facing Voice Focus toggle without consulting audio
/// hardware. A missing preference is deliberately standard capture: Voice
/// Focus is an explicit opt-in because enabling Apple's voice-processing I/O
/// changes the audio graph and is not reliable on every Mac/device pairing.
public enum VoiceFocusPreferencePolicy {
    public static func isEnabled(storedPreference: Bool?) -> Bool {
        storedPreference ?? false
    }
}

/// Remembers a voice-processing path that started successfully but delivered
/// only silence. The current capture can rebuild on the standard microphone
/// path, later captures keep that stable choice, and an explicit Voice Focus
/// re-enable gives voice processing one fresh attempt.
struct VoiceProcessingRecoveryState: Equatable {
    /// Ignore taps shorter than 0.3 seconds so an accidental click cannot
    /// disable Voice Focus for the rest of the session.
    static let minimumSilentCaptureSamples = 4_800

    private(set) var shouldUseStandardCapture = false

    func effectivePreference(
        for configuredPreference: VoiceProcessingPreference
    ) -> VoiceProcessingPreference {
        shouldUseStandardCapture ? .disabled : configuredPreference
    }

    @discardableResult
    mutating func recordCapture(
        wasVoiceProcessingActive: Bool,
        samples: [Float]
    ) -> Bool {
        guard wasVoiceProcessingActive,
            samples.count >= Self.minimumSilentCaptureSamples,
            AudioCaptureManager.isSilentCapture(samples)
        else { return false }

        shouldUseStandardCapture = true
        return true
    }

    mutating func preferenceChanged(to preference: VoiceProcessingPreference) {
        if preference == .automatic {
            shouldUseStandardCapture = false
        }
    }

    mutating func requireStandardCapture() {
        shouldUseStandardCapture = true
    }
}

/// Tracks the callback heartbeat of a newly started capture graph. A quiet
/// buffer is still a healthy delivered buffer; signal energy is never a reason
/// to tear down a live graph. Only a missing callback heartbeat requests
/// same-attempt recovery. Completed silent Voice Focus capture is handled
/// separately by `VoiceProcessingRecoveryState` and affects the *next* attempt.
struct CaptureSignalProbe: Equatable {
    static let minimumRecoveryAge: TimeInterval = 1.0
    static let starvedTapGracePeriod: TimeInterval = 1.0

    private(set) var sampleCount = 0
    private(set) var peak: Float = 0
    private(set) var lastBufferAt: TimeInterval?
    private(set) var recoveryRequested = false

    mutating func reset() {
        sampleCount = 0
        peak = 0
        lastBufferAt = nil
        recoveryRequested = false
    }

    mutating func record(sampleCount: Int, peak: Float, at uptime: TimeInterval) {
        guard sampleCount > 0, !recoveryRequested else { return }
        self.sampleCount += sampleCount
        self.peak = max(self.peak, abs(peak))
        lastBufferAt = uptime
    }

    /// Returns true once when no audio callback has arrived for the starvation
    /// grace period. Continuous near-zero buffers prove the tap is alive and do
    /// not request a restart.
    mutating func requestRecovery(
        recordingAge: TimeInterval,
        at uptime: TimeInterval
    ) -> Bool {
        guard !recoveryRequested,
            recordingAge >= Self.minimumRecoveryAge
        else { return false }
        let heartbeatAge =
            lastBufferAt.map { max(0, uptime - $0) }
            ?? recordingAge
        guard heartbeatAge >= Self.starvedTapGracePeriod else { return false }
        recoveryRequested = true
        return true
    }
}

/// Measures the age of the currently running audio graph. A configuration
/// change creates a fresh graph, so its starvation grace period must also start
/// fresh instead of inheriting the age of the overall dictation or meeting.
struct CaptureAttemptClock: Equatable {
    private(set) var startedAt: TimeInterval?

    mutating func start(at uptime: TimeInterval) {
        startedAt = uptime
    }

    mutating func stop() {
        startedAt = nil
    }

    func age(at uptime: TimeInterval) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, uptime - startedAt)
    }
}

enum CaptureRecoveryTrigger: Equatable {
    case tapStarvation
    case configurationChange
}

enum CaptureRecoveryAction: Equatable {
    case retireGraph(trigger: CaptureRecoveryTrigger)
    case restartStandard(attempt: Int, trigger: CaptureRecoveryTrigger)
}

enum CaptureRecoveryFailureDisposition: Equatable {
    case retryScheduled
    case exhausted
}

/// Pure scheduling state for route/configuration recovery. Notification
/// callbacks only enqueue work. The controller's existing health poll performs
/// at most one restart after the graph has had time to settle, and transient
/// failures receive one bounded retry.
struct CaptureRecoveryCoordinator: Equatable {
    static let settleDelay: TimeInterval = 0.5
    static let postTeardownDelay: TimeInterval = 0.5
    /// After the first restart attempt, give a changing Bluetooth, USB, or
    /// aggregate route progressively more time to become available. Every
    /// attempt still creates a fresh engine and re-reads the native input
    /// format, so these bounded retries also act as device-readiness polls.
    static let restartRetryDelays: [TimeInterval] = [0.5, 1.0, 2.0]
    static let maximumRestartAttempts = restartRetryDelays.count + 1

    static func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= restartRetryDelays.count else {
            return nil
        }
        return restartRetryDelays[attempt - 1]
    }

    private enum State: Equatable {
        case idle
        case waitingToRetire(
            trigger: CaptureRecoveryTrigger,
            readyAt: TimeInterval
        )
        case retiring(trigger: CaptureRecoveryTrigger)
        case waitingToRestart(
            trigger: CaptureRecoveryTrigger,
            readyAt: TimeInterval,
            attempt: Int
        )
        case restarting(trigger: CaptureRecoveryTrigger, attempt: Int)
    }

    private var state: State = .idle

    var hasPendingWork: Bool {
        state != .idle
    }

    var isRestarting: Bool {
        if case .restarting = state { return true }
        return false
    }

    var isRetiring: Bool {
        if case .retiring = state { return true }
        return false
    }

    mutating func schedule(
        _ trigger: CaptureRecoveryTrigger,
        at uptime: TimeInterval
    ) {
        switch state {
        case .idle:
            state = .waitingToRetire(
                trigger: trigger,
                readyAt: uptime + Self.settleDelay
            )
        case .waitingToRetire:
            // A configuration storm extends the quiet period while retaining
            // one pending retirement.
            state = .waitingToRetire(
                trigger: trigger,
                readyAt: uptime + Self.settleDelay
            )
        case .retiring, .waitingToRestart, .restarting:
            // Never overlap restarts. A notification from the graph being
            // retired is made obsolete by the active-session token as well.
            break
        }
    }

    mutating func nextAction(at uptime: TimeInterval) -> CaptureRecoveryAction? {
        switch state {
        case .waitingToRetire(let trigger, let readyAt)
        where uptime >= readyAt:
            state = .retiring(trigger: trigger)
            return .retireGraph(trigger: trigger)
        case .waitingToRestart(let trigger, let readyAt, let attempt)
        where uptime >= readyAt:
            state = .restarting(trigger: trigger, attempt: attempt)
            return .restartStandard(attempt: attempt, trigger: trigger)
        default:
            return nil
        }
    }

    mutating func graphRetired(at uptime: TimeInterval) {
        guard case .retiring(let trigger) = state else { return }
        state = .waitingToRestart(
            trigger: trigger,
            readyAt: uptime + Self.postTeardownDelay,
            attempt: 1
        )
    }

    mutating func restartSucceeded() {
        guard case .restarting = state else { return }
        state = .idle
    }

    mutating func restartFailed(
        at uptime: TimeInterval
    ) -> CaptureRecoveryFailureDisposition {
        guard case .restarting(let trigger, let attempt) = state else {
            return .exhausted
        }
        guard let retryDelay = Self.retryDelay(afterFailedAttempt: attempt) else {
            state = .idle
            return .exhausted
        }
        state = .waitingToRestart(
            trigger: trigger,
            readyAt: uptime + retryDelay,
            attempt: attempt + 1
        )
        return .retryScheduled
    }

    mutating func cancel() {
        state = .idle
    }
}

/// Latches a terminal graph-restart failure until capture is explicitly
/// finished or a replacement graph starts successfully. The controller polls
/// health, so a failed asynchronous configuration restart must remain visible
/// instead of being reduced to a log line.
struct CaptureFailureLatch: Equatable {
    private(set) var failure: AudioCaptureError?

    mutating func record(_ error: Error) {
        failure =
            (error as? AudioCaptureError)
            ?? .engineFailed(error.localizedDescription)
    }

    mutating func clear() {
        failure = nil
    }
}

/// Owns the preserved sample stream and rejects callbacks from obsolete audio
/// graphs. Advancing the generation when replacement begins, or after drain or
/// discard, preserves callbacks that finish during teardown while preventing a
/// later callback from repopulating a drained buffer or poisoning a new graph's
/// signal probe.
struct CaptureSampleStore: Equatable {
    typealias Generation = UInt64

    private(set) var generation: Generation = 0
    private(set) var samples: [Float] = []

    var count: Int { samples.count }

    mutating func begin(preservingExisting: Bool) -> Generation {
        generation &+= 1
        if !preservingExisting { samples = [] }
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    @discardableResult
    mutating func append(_ newSamples: [Float], generation callbackGeneration: Generation) -> Bool {
        guard callbackGeneration == generation else { return false }
        samples.append(contentsOf: newSamples)
        return true
    }

    mutating func drain() -> [Float] {
        invalidate()
        let result = samples
        samples = []
        return result
    }

    mutating func discard() {
        invalidate()
        samples = []
    }
}

/// Atomic result of ending capture. A device-restart error can race a manual
/// stop, so callers receive the preserved samples and terminal error together.
public struct AudioCaptureStopResult: Sendable, Equatable {
    public let samples: [Float]
    public let terminalError: AudioCaptureError?

    public init(samples: [Float], terminalError: AudioCaptureError?) {
        self.samples = samples
        self.terminalError = terminalError
    }
}

/// Captures microphone audio and delivers 16 kHz mono Float32 samples suitable for Parakeet.
public final class AudioCaptureManager: @unchecked Sendable {
    /// Distinguishes a dead or muted input path from ordinary room silence.
    /// Real microphone input carries a noise floor above this threshold even
    /// when nobody is speaking; a starved voice-processing tap sits near zero.
    public static func isSilentCapture(
        _ samples: [Float],
        threshold: Float = 0.0005
    ) -> Bool {
        guard !samples.isEmpty else { return true }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        return peak < threshold
    }

    public static let targetSampleRate: Double = 16_000

    private var engine: (any AudioCaptureEngineSession)?
    private var activeEngineGeneration: CaptureSampleStore.Generation?
    private var sampleStore = CaptureSampleStore()
    private let stateLock = NSLock()
    private let engineFactory: any AudioCaptureEngineStarting
    private let uptime: () -> TimeInterval
    private var voiceProcessingPreference: VoiceProcessingPreference
    private var voiceProcessingRecovery = VoiceProcessingRecoveryState()
    private var captureSignalProbe = CaptureSignalProbe()
    private var captureAttemptClock = CaptureAttemptClock()
    private var recoveryCoordinator = CaptureRecoveryCoordinator()
    private var captureFailure = CaptureFailureLatch()
    private var lifecycleGeneration: UInt64 = 0
    public private(set) var isRecording = false
    public private(set) var isVoiceProcessingActive = false

    /// Called from an audio render thread with a 0...1 input level.
    public var onLevel: ((Float) -> Void)?

    public init(voiceProcessing: VoiceProcessingPreference = .disabled) {
        self.voiceProcessingPreference = voiceProcessing
        self.engineFactory = SystemAudioCaptureEngineFactory()
        self.uptime = { ProcessInfo.processInfo.systemUptime }
    }

    /// Internal state-injection seam for lifecycle regression tests that must
    /// exercise stop/health behavior without opening real audio hardware.
    init(
        voiceProcessing: VoiceProcessingPreference,
        sampleStore: CaptureSampleStore,
        isRecording: Bool
    ) {
        self.voiceProcessingPreference = voiceProcessing
        self.sampleStore = sampleStore
        self.isRecording = isRecording
        self.engineFactory = SystemAudioCaptureEngineFactory()
        self.uptime = { ProcessInfo.processInfo.systemUptime }
    }

    /// Hardware-free engine and clock injection used by lifecycle tests.
    init(
        voiceProcessing: VoiceProcessingPreference = .disabled,
        engineFactory: any AudioCaptureEngineStarting,
        uptime: @escaping () -> TimeInterval
    ) {
        self.voiceProcessingPreference = voiceProcessing
        self.engineFactory = engineFactory
        self.uptime = uptime
    }

    @discardableResult
    func latchCaptureFailure(_ error: Error) -> AudioCaptureError {
        stateLock.lock()
        captureFailure.record(error)
        let failure =
            captureFailure.failure
            ?? .engineFailed(error.localizedDescription)
        stateLock.unlock()
        return failure
    }

    public func setVoiceProcessingPreference(_ preference: VoiceProcessingPreference) {
        guard !isRecording else { return }
        voiceProcessingPreference = preference
        // A user who turns Voice Focus back on is explicitly asking us to
        // retry it. Without clearing the latch, the toggle looked enabled but
        // standard capture remained active until the app was relaunched.
        voiceProcessingRecovery.preferenceChanged(to: preference)
    }

    public static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public var capturedDuration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Double(sampleStore.count) / Self.targetSampleRate
    }

    public func start(preserveSamples: Bool = false) throws {
        stateLock.lock()
        guard !isRecording else {
            stateLock.unlock()
            return
        }
        lifecycleGeneration &+= 1
        let startLifecycle = lifecycleGeneration
        isVoiceProcessingActive = false
        activeEngineGeneration = nil
        recoveryCoordinator.cancel()
        if !preserveSamples {
            captureFailure.clear()
        }
        let effectivePreference = voiceProcessingRecovery.effectivePreference(
            for: voiceProcessingPreference
        )
        stateLock.unlock()

        var lastError: Error?
        var preserveForAttempt = preserveSamples
        for preference in VoiceProcessingAttemptPlan.preferences(for: effectivePreference) {
            stateLock.lock()
            guard lifecycleGeneration == startLifecycle else {
                stateLock.unlock()
                throw AudioCaptureError.engineFailed("Capture start was cancelled.")
            }
            let generation = sampleStore.begin(
                preservingExisting: preserveForAttempt
            )
            captureSignalProbe.reset()
            captureAttemptClock.stop()
            stateLock.unlock()
            preserveForAttempt = true
            do {
                let started = try makeStartedEngineSession(
                    preference: preference,
                    generation: generation
                )
                stateLock.lock()
                // A concurrent cancel invalidates the sample generation. Never
                // attach a graph whose callbacks have already become obsolete.
                guard lifecycleGeneration == startLifecycle,
                    sampleStore.generation == generation,
                    !isRecording
                else {
                    stateLock.unlock()
                    started.stop()
                    throw AudioCaptureError.engineFailed("Capture start was cancelled.")
                }
                engine = started
                activeEngineGeneration = generation
                isRecording = true
                isVoiceProcessingActive = started.activation == .enabled
                captureFailure.clear()
                captureAttemptClock.start(at: uptime())
                stateLock.unlock()
                observeConfigurationChanges(
                    for: started,
                    generation: generation
                )
                switch started.activation {
                case .enabled:
                    FlowLog.info("system voice processing enabled for microphone capture")
                case .disabledByPreference:
                    FlowLog.info("using standard microphone capture")
                case .unavailable:
                    break
                }
                FlowLog.pipeline(
                    "audio capture started nativeSR=\(started.nativeSampleRate) voiceProcessing=\(isVoiceProcessingActive)"
                )
                return
            } catch {
                lastError = error
                stateLock.lock()
                let startIsCurrent = lifecycleGeneration == startLifecycle
                stateLock.unlock()
                guard startIsCurrent else {
                    throw AudioCaptureError.engineFailed("Capture start was cancelled.")
                }
                guard preference == .automatic else { throw error }
                FlowLog.info(
                    "voice-processing capture setup failed — retrying standard microphone capture"
                )
            }
        }
        throw lastError ?? AudioCaptureError.noInputDevice
    }

    /// Advances deferred graph recovery from the controller's health poll. A
    /// configuration notification only schedules this work; no AVAudioEngine is
    /// torn down from inside its notification callback. Callback starvation is
    /// monitored for both standard and Voice Focus capture so the default path
    /// cannot remain visibly recording on a dead tap.
    @discardableResult
    public func recoverCaptureIfNeeded() throws -> Bool {
        let currentUptime = uptime()
        stateLock.lock()
        if let failure = captureFailure.failure {
            stateLock.unlock()
            throw failure
        }
        guard isRecording else {
            stateLock.unlock()
            return false
        }
        var scheduledStarvationRecovery = false
        let attemptAge = captureAttemptClock.age(at: currentUptime)
        if captureSignalProbe.requestRecovery(
            recordingAge: attemptAge,
            at: currentUptime
        ) {
            // Every replacement uses the stable standard path. Latch that path
            // for later captures too when an automatic graph was selected.
            voiceProcessingRecovery.requireStandardCapture()
            recoveryCoordinator.schedule(.tapStarvation, at: currentUptime)
            scheduledStarvationRecovery = true
        }
        let action = recoveryCoordinator.nextAction(at: currentUptime)
        stateLock.unlock()
        if scheduledStarvationRecovery {
            FlowLog.info("microphone callback heartbeat stopped — recovery scheduled")
        }
        guard let action else { return false }
        switch action {
        case .retireGraph:
            retireCurrentGraphForRecovery()
            return false
        case .restartStandard:
            return try performStandardRecovery()
        }
    }

    /// Compatibility entry point retained while application call sites move to
    /// the capture-wide name above.
    @discardableResult
    public func recoverSilentVoiceProcessingIfNeeded() throws -> Bool {
        try recoverCaptureIfNeeded()
    }

    private func retireCurrentGraphForRecovery() {
        stateLock.lock()
        guard isRecording, recoveryCoordinator.isRetiring else {
            stateLock.unlock()
            return
        }
        let retiringEngine = engine
        engine = nil
        activeEngineGeneration = nil
        isVoiceProcessingActive = false
        captureAttemptClock.stop()
        stateLock.unlock()

        // Stop and release the old VPIO/standard graph outside the notification
        // callback and lock. The coordinator then waits an additional explicit
        // settling interval before a fresh standard graph can be created.
        retiringEngine?.stop()

        stateLock.lock()
        guard isRecording, recoveryCoordinator.isRetiring else {
            stateLock.unlock()
            return
        }
        recoveryCoordinator.graphRetired(at: uptime())
        stateLock.unlock()
        FlowLog.info("microphone graph retired — standard restart is settling")
    }

    private func performStandardRecovery() throws -> Bool {
        stateLock.lock()
        guard isRecording, recoveryCoordinator.isRestarting else {
            stateLock.unlock()
            return false
        }
        let generation = sampleStore.begin(preservingExisting: true)
        captureSignalProbe.reset()
        stateLock.unlock()

        do {
            let replacement = try makeStartedEngineSession(
                preference: .disabled,
                generation: generation
            )
            stateLock.lock()
            guard isRecording,
                recoveryCoordinator.isRestarting,
                sampleStore.generation == generation
            else {
                stateLock.unlock()
                replacement.stop()
                return false
            }
            engine = replacement
            activeEngineGeneration = generation
            isVoiceProcessingActive = false
            captureFailure.clear()
            captureAttemptClock.start(at: uptime())
            recoveryCoordinator.restartSucceeded()
            stateLock.unlock()
            observeConfigurationChanges(
                for: replacement,
                generation: generation
            )
            FlowLog.info("microphone capture recovered on the standard path")
            return true
        } catch {
            stateLock.lock()
            guard isRecording, recoveryCoordinator.isRestarting else {
                stateLock.unlock()
                return false
            }
            let disposition = recoveryCoordinator.restartFailed(at: uptime())
            if disposition == .retryScheduled {
                stateLock.unlock()
                FlowLog.info("standard microphone restart deferred for one retry")
                return false
            }
            captureFailure.record(error)
            let failure =
                captureFailure.failure
                ?? .engineFailed(error.localizedDescription)
            isRecording = false
            activeEngineGeneration = nil
            stateLock.unlock()
            FlowLog.error("standard microphone restart exhausted")
            throw failure
        }
    }

    private func makeStartedEngineSession(
        preference: VoiceProcessingPreference,
        generation: CaptureSampleStore.Generation
    ) throws -> any AudioCaptureEngineSession {
        try engineFactory.start(
            preference: preference
        ) { [weak self] samples, level, peak in
            self?.acceptSamples(
                samples,
                level: level,
                peak: peak,
                generation: generation
            )
        }
    }

    private func observeConfigurationChanges(
        for engine: any AudioCaptureEngineSession,
        generation: CaptureSampleStore.Generation
    ) {
        engine.observeConfigurationChanges { [weak self] in
            self?.configurationChanged(for: generation)
        }
    }

    private func configurationChanged(
        for generation: CaptureSampleStore.Generation
    ) {
        let currentUptime = uptime()
        stateLock.lock()
        guard isRecording,
            activeEngineGeneration == generation
        else {
            stateLock.unlock()
            return
        }
        voiceProcessingRecovery.requireStandardCapture()
        recoveryCoordinator.schedule(
            .configurationChange,
            at: currentUptime
        )
        stateLock.unlock()
        FlowLog.info("audio configuration change queued for settled recovery")
    }

    private func acceptSamples(
        _ samples: [Float],
        level: Float,
        peak: Float,
        generation: CaptureSampleStore.Generation
    ) {
        stateLock.lock()
        guard sampleStore.generation == generation, captureFailure.failure == nil else {
            stateLock.unlock()
            return
        }
        // Never forward invalid device/converter output into voice detection or
        // recognition. Preserve earlier valid audio for the existing partial-
        // recording recovery path; later callbacks cannot extend a failed stream.
        guard level.isFinite, peak.isFinite, samples.allSatisfy(\.isFinite) else {
            captureFailure.record(
                AudioCaptureError.engineFailed(
                    "The microphone delivered invalid audio. Earlier captured audio is preserved."
                )
            )
            stateLock.unlock()
            return
        }
        let accepted = sampleStore.append(samples, generation: generation)
        if accepted {
            captureSignalProbe.record(
                sampleCount: samples.count,
                peak: peak,
                at: uptime()
            )
        }
        stateLock.unlock()
        guard accepted else { return }
        onLevel?(level)
    }

    /// Stops capture and atomically returns all preserved samples plus any
    /// asynchronous restart failure. This drains even when the engine already
    /// stopped, so a failed configuration restart cannot strand user audio.
    @discardableResult
    public func stopWithResult() -> AudioCaptureStopResult {
        stateLock.lock()
        let stoppedEngine = engine
        lifecycleGeneration &+= 1
        engine = nil
        activeEngineGeneration = nil
        isRecording = false
        let wasVoiceProcessing = isVoiceProcessingActive
        isVoiceProcessingActive = false
        recoveryCoordinator.cancel()
        captureAttemptClock.stop()
        stateLock.unlock()

        // Preserve callbacks already finishing during teardown, then invalidate
        // their generation atomically when the sample stream is drained.
        stoppedEngine?.stop()
        stateLock.lock()
        let samples = sampleStore.drain()
        let terminalError = captureFailure.failure
        captureFailure.clear()
        captureSignalProbe.reset()
        captureAttemptClock.stop()
        stateLock.unlock()
        if voiceProcessingRecovery.recordCapture(
            wasVoiceProcessingActive: wasVoiceProcessing,
            samples: samples
        ) {
            FlowLog.info(
                "voice processing produced a silent capture — using standard microphone capture next"
            )
        }
        FlowLog.pipeline(
            "audio capture stopped seconds=\(Double(samples.count) / Self.targetSampleRate)")
        return AudioCaptureStopResult(
            samples: samples,
            terminalError: terminalError
        )
    }

    /// Backward-compatible sample-only stop. Callers that need to distinguish
    /// an interrupted graph should use `stopWithResult()`.
    @discardableResult
    public func stop() -> [Float] {
        stopWithResult().samples
    }

    public func cancel() {
        stateLock.lock()
        let cancelledEngine = engine
        lifecycleGeneration &+= 1
        engine = nil
        activeEngineGeneration = nil
        isRecording = false
        isVoiceProcessingActive = false
        recoveryCoordinator.cancel()
        captureAttemptClock.stop()
        stateLock.unlock()

        cancelledEngine?.stop()
        stateLock.lock()
        sampleStore.discard()
        captureFailure.clear()
        captureSignalProbe.reset()
        captureAttemptClock.stop()
        stateLock.unlock()
    }
}
