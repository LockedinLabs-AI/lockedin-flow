import XCTest

@testable import AudioCapture

final class CaptureRecoveryCoordinatorTests: XCTestCase {
    func testConfigurationStormCoalescesAndWaitsForQuietPeriod() {
        var coordinator = CaptureRecoveryCoordinator()

        coordinator.schedule(.configurationChange, at: 10)
        XCTAssertNil(coordinator.nextAction(at: 10.49))

        coordinator.schedule(.configurationChange, at: 10.4)
        XCTAssertNil(coordinator.nextAction(at: 10.89))
        XCTAssertEqual(
            coordinator.nextAction(at: 10.9),
            .retireGraph(trigger: .configurationChange)
        )
        XCTAssertNil(coordinator.nextAction(at: 20))
        XCTAssertTrue(coordinator.isRetiring)

        coordinator.graphRetired(at: 20)
        XCTAssertNil(
            coordinator.nextAction(
                at: 20 + CaptureRecoveryCoordinator.postTeardownDelay - 0.01
            )
        )
        XCTAssertEqual(
            coordinator.nextAction(
                at: 20 + CaptureRecoveryCoordinator.postTeardownDelay
            ),
            .restartStandard(attempt: 1, trigger: .configurationChange)
        )
    }

    func testRestartFailuresUseBoundedBackoffThenExhaust() throws {
        var coordinator = CaptureRecoveryCoordinator()
        coordinator.schedule(.tapStarvation, at: 0)
        XCTAssertEqual(
            coordinator.nextAction(at: CaptureRecoveryCoordinator.settleDelay),
            .retireGraph(trigger: .tapStarvation)
        )
        coordinator.graphRetired(at: CaptureRecoveryCoordinator.settleDelay)
        XCTAssertEqual(
            coordinator.nextAction(
                at: CaptureRecoveryCoordinator.settleDelay
                    + CaptureRecoveryCoordinator.postTeardownDelay
            ),
            .restartStandard(attempt: 1, trigger: .tapStarvation)
        )

        var now: TimeInterval = 1
        for attempt in 1..<CaptureRecoveryCoordinator.maximumRestartAttempts {
            XCTAssertEqual(coordinator.restartFailed(at: now), .retryScheduled)
            let delay = try XCTUnwrap(
                CaptureRecoveryCoordinator.retryDelay(afterFailedAttempt: attempt)
            )
            XCTAssertNil(coordinator.nextAction(at: now + delay - 0.01))
            now += delay
            XCTAssertEqual(
                coordinator.nextAction(at: now),
                .restartStandard(
                    attempt: attempt + 1,
                    trigger: .tapStarvation
                )
            )
        }
        XCTAssertEqual(coordinator.restartFailed(at: now), .exhausted)
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testRestartBackoffIsProgressiveAndFinite() {
        XCTAssertEqual(
            CaptureRecoveryCoordinator.restartRetryDelays,
            [0.5, 1.0, 2.0]
        )
        XCTAssertEqual(CaptureRecoveryCoordinator.maximumRestartAttempts, 4)
        XCTAssertNil(
            CaptureRecoveryCoordinator.retryDelay(afterFailedAttempt: 0)
        )
        XCTAssertNil(
            CaptureRecoveryCoordinator.retryDelay(
                afterFailedAttempt: CaptureRecoveryCoordinator.maximumRestartAttempts
            )
        )
    }

    func testSuccessfulRestartAndCancellationClearPendingWork() {
        var coordinator = CaptureRecoveryCoordinator()
        coordinator.schedule(.configurationChange, at: 0)
        coordinator.cancel()
        XCTAssertNil(coordinator.nextAction(at: 10))

        coordinator.schedule(.tapStarvation, at: 20)
        XCTAssertNotNil(
            coordinator.nextAction(
                at: 20 + CaptureRecoveryCoordinator.settleDelay
            )
        )
        coordinator.graphRetired(
            at: 20 + CaptureRecoveryCoordinator.settleDelay
        )
        XCTAssertNotNil(
            coordinator.nextAction(
                at: 20
                    + CaptureRecoveryCoordinator.settleDelay
                    + CaptureRecoveryCoordinator.postTeardownDelay
            )
        )
        coordinator.restartSucceeded()

        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertNil(coordinator.nextAction(at: 100))
    }

    func testSchedulingWhileRetiringOrRestartingNeverCreatesOverlap() {
        var coordinator = CaptureRecoveryCoordinator()
        coordinator.schedule(.configurationChange, at: 0)
        XCTAssertNotNil(
            coordinator.nextAction(at: CaptureRecoveryCoordinator.settleDelay)
        )

        coordinator.schedule(.configurationChange, at: 1)

        XCTAssertNil(coordinator.nextAction(at: 100))
        XCTAssertTrue(coordinator.isRetiring)

        coordinator.graphRetired(at: 100)
        XCTAssertNotNil(
            coordinator.nextAction(
                at: 100 + CaptureRecoveryCoordinator.postTeardownDelay
            )
        )
        coordinator.schedule(.configurationChange, at: 101)

        XCTAssertNil(coordinator.nextAction(at: 200))
        XCTAssertTrue(coordinator.isRestarting)
    }
}

final class AudioCaptureRecoveryLifecycleTests: XCTestCase {
    func testInvalidAudioStopsSafelyAndPreservesEarlierSamples() throws {
        for invalid in [Float.nan, .infinity, -.infinity] {
            let clock = TestUptime()
            let factory = FakeAudioCaptureEngineFactory(outcomes: [.success])
            let manager = makeManager(clock: clock, factory: factory)
            try manager.start()
            let session = try XCTUnwrap(factory.sessions.first)
            session.deliver([0.1, 0.2])
            session.deliver([0.3, invalid])
            session.deliver([0.4])
            XCTAssertThrowsError(try manager.recoverCaptureIfNeeded())
            let result = manager.stopWithResult()
            XCTAssertNotNil(result.terminalError)
            XCTAssertEqual(result.samples, [0.1, 0.2])
            XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        }
    }

    func testNewCaptureAfterInvalidAudioDoesNotInheritFailure() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = makeManager(clock: clock, factory: factory)
        try manager.start()
        let old = try XCTUnwrap(factory.sessions.first)
        old.deliver([.nan])
        XCTAssertNotNil(manager.stopWithResult().terminalError)
        try manager.start()
        old.deliver([.infinity])
        try XCTUnwrap(factory.sessions.last).deliver([0.5])
        XCTAssertFalse(try manager.recoverCaptureIfNeeded())
        let result = manager.stopWithResult()
        XCTAssertNil(result.terminalError)
        XCTAssertEqual(result.samples, [0.5])
    }

    func testManagerDefaultsToStandardCaptureWithoutTouchingHardware() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success])
        let manager = AudioCaptureManager(
            engineFactory: factory,
            uptime: { clock.now }
        )

        try manager.start()

        XCTAssertEqual(factory.startPreferences, [.disabled])
        XCTAssertFalse(manager.isVoiceProcessingActive)
        _ = manager.stopWithResult()
    }

    func testCancelDuringInitialStartRejectsReturnedSessionAndSkipsFallback() {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success])
        var manager: AudioCaptureManager!
        factory.beforeReturningSession = {
            manager.cancel()
        }
        manager = makeManager(clock: clock, factory: factory)

        XCTAssertThrowsError(try manager.start())

        XCTAssertEqual(factory.startPreferences, [.automatic])
        XCTAssertEqual(factory.sessions.first?.stopCount, 1)
        XCTAssertFalse(manager.isRecording)
        factory.beforeReturningSession = nil
    }

    func testConfigurationNotificationOnlySchedulesThenRestartsStandard() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.1, 0.2])
        clock.now = 0.2

        original.sendConfigurationChange()

        XCTAssertEqual(factory.startPreferences, [.automatic])
        XCTAssertEqual(original.stopCount, 0)
        clock.now = 0.69
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(original.stopCount, 0)

        clock.now = 0.7
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic])
        XCTAssertEqual(original.stopCount, 1)

        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertTrue(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic, .disabled])
        XCTAssertEqual(original.stopCount, 1)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
        XCTAssertEqual(manager.stopWithResult().samples, [0.1, 0.2])
    }

    func testConfigurationChangeOnStandardCaptureStillUsesSettledStandardRebuild() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = AudioCaptureManager(
            voiceProcessing: .disabled,
            engineFactory: factory,
            uptime: { clock.now }
        )

        try manager.start()
        try XCTUnwrap(factory.sessions.first).sendConfigurationChange()
        XCTAssertEqual(factory.startPreferences, [.disabled])

        clock.now = CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertTrue(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.disabled, .disabled])
        _ = manager.stopWithResult()
    }

    func testContinuousNearZeroBuffersNeverTriggerLiveRecoveryButLatchNextCapture() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let voiceFocused = try XCTUnwrap(factory.sessions.first)
        clock.now = 0.75
        voiceFocused.deliver([Float](repeating: 0.00001, count: 4_800))
        clock.now = 1.5
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        voiceFocused.deliver([Float](repeating: 0.00001, count: 4_800))
        clock.now = 2.25
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic])

        let completed = manager.stopWithResult()
        XCTAssertEqual(completed.samples.count, 9_600)
        try manager.start()

        XCTAssertEqual(factory.startPreferences, [.automatic, .disabled])
        _ = manager.stopWithResult()
    }

    func testTrulyStarvedVoiceProcessingTapRecoversAfterSettleDelay() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        clock.now = CaptureSignalProbe.starvedTapGracePeriod
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic])

        clock.now += CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic])

        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertTrue(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic, .disabled])
        _ = manager.stopWithResult()
    }

    func testTrulyStarvedStandardTapAlsoRecoversAndPreservesSamples() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = AudioCaptureManager(
            voiceProcessing: .disabled,
            engineFactory: factory,
            uptime: { clock.now }
        )

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.1, 0.2])

        clock.now = CaptureSignalProbe.starvedTapGracePeriod
        XCTAssertFalse(try manager.recoverCaptureIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.disabled])

        clock.now += CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverCaptureIfNeeded())
        XCTAssertEqual(original.stopCount, 1)

        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertTrue(try manager.recoverCaptureIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.disabled, .disabled])
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
        XCTAssertEqual(manager.stopWithResult().samples, [0.1, 0.2])
    }

    func testTransientStandardRestartFailureRetriesAfterSettlementAndPreservesSamples() throws {
        let clock = TestUptime()
        let transient = AudioCaptureError.engineFailed("transient")
        let factory = FakeAudioCaptureEngineFactory(
            outcomes: [.success, .failure(transient), .success]
        )
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.1, 0.2])
        original.sendConfigurationChange()

        clock.now = CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertTrue(manager.isRecording)
        XCTAssertEqual(factory.startPreferences, [.automatic])

        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertTrue(manager.isRecording)
        XCTAssertEqual(factory.startPreferences, [.automatic, .disabled])

        let firstRetryDelay = try XCTUnwrap(
            CaptureRecoveryCoordinator.retryDelay(afterFailedAttempt: 1)
        )
        clock.now += firstRetryDelay - 0.01
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        clock.now += 0.01
        XCTAssertTrue(try manager.recoverSilentVoiceProcessingIfNeeded())

        XCTAssertEqual(
            factory.startPreferences,
            [.automatic, .disabled, .disabled]
        )
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
        XCTAssertEqual(manager.stopWithResult().samples, [0.1, 0.2])
    }

    func testExhaustedStandardRestartFailsTruthfullyWithPreservedSamples() throws {
        let clock = TestUptime()
        let firstFailure = AudioCaptureError.engineFailed("first transient")
        let secondFailure = AudioCaptureError.engineFailed("still settling")
        let thirdFailure = AudioCaptureError.engineFailed("route unavailable")
        let finalFailure = AudioCaptureError.engineFailed("still unavailable")
        let factory = FakeAudioCaptureEngineFactory(
            outcomes: [
                .success,
                .failure(firstFailure),
                .failure(secondFailure),
                .failure(thirdFailure),
                .failure(finalFailure),
            ]
        )
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.3, 0.4])
        original.sendConfigurationChange()
        clock.now = CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())

        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())

        for failedAttempt in 1..<(CaptureRecoveryCoordinator.maximumRestartAttempts - 1) {
            clock.now += try XCTUnwrap(
                CaptureRecoveryCoordinator.retryDelay(
                    afterFailedAttempt: failedAttempt
                )
            )
            XCTAssertFalse(try manager.recoverCaptureIfNeeded())
            XCTAssertTrue(manager.isRecording)
        }

        clock.now += try XCTUnwrap(
            CaptureRecoveryCoordinator.retryDelay(
                afterFailedAttempt: CaptureRecoveryCoordinator.maximumRestartAttempts - 1
            )
        )
        XCTAssertThrowsError(try manager.recoverCaptureIfNeeded()) {
            XCTAssertEqual($0 as? AudioCaptureError, finalFailure)
        }
        XCTAssertFalse(manager.isRecording)

        let stopped = manager.stopWithResult()
        XCTAssertEqual(stopped.samples, [0.3, 0.4])
        XCTAssertEqual(stopped.terminalError, finalFailure)
    }

    func testManualStopClearsPendingConfigurationRecovery() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.2])
        original.sendConfigurationChange()

        XCTAssertEqual(manager.stopWithResult().samples, [0.2])
        clock.now = 10
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic])
    }

    func testManualStopDuringPendingRetryPreventsAnotherRestart() throws {
        let clock = TestUptime()
        let transient = AudioCaptureError.engineFailed("transient")
        let factory = FakeAudioCaptureEngineFactory(
            outcomes: [.success, .failure(transient)]
        )
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.4])
        original.sendConfigurationChange()
        clock.now = CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        original.sendConfigurationChange()
        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())

        XCTAssertEqual(manager.stopWithResult().samples, [0.4])
        clock.now += try XCTUnwrap(
            CaptureRecoveryCoordinator.retryDelay(afterFailedAttempt: 1)
        )
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(factory.startPreferences, [.automatic, .disabled])
    }

    func testCancelClearsPendingRecoveryAndDiscardsSamples() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([0.2])
        original.sendConfigurationChange()
        manager.cancel()

        clock.now = 10
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        XCTAssertEqual(manager.stopWithResult().samples, [])
        XCTAssertEqual(factory.startPreferences, [.automatic])
    }

    func testObsoleteEngineCallbacksAreRejectedAfterReplacement() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [.success, .success])
        let manager = makeManager(clock: clock, factory: factory)

        try manager.start()
        let original = try XCTUnwrap(factory.sessions.first)
        original.deliver([1])
        original.sendConfigurationChange()
        clock.now = CaptureRecoveryCoordinator.settleDelay
        XCTAssertFalse(try manager.recoverSilentVoiceProcessingIfNeeded())
        original.sendConfigurationChange()
        clock.now += CaptureRecoveryCoordinator.postTeardownDelay
        XCTAssertTrue(try manager.recoverSilentVoiceProcessingIfNeeded())

        original.deliver([99])
        try XCTUnwrap(factory.sessions.last).deliver([2])

        XCTAssertEqual(manager.stopWithResult().samples, [1, 2])
    }

    func testTwoHundredRouteChangesPreserveEachDictationWithoutLeakingOldCallbacks() throws {
        let clock = TestUptime()
        let factory = FakeAudioCaptureEngineFactory(outcomes: [])
        let manager = AudioCaptureManager(
            voiceProcessing: .disabled,
            engineFactory: factory,
            uptime: { clock.now }
        )

        for cycle in 0..<200 {
            clock.now += 1
            try manager.start()
            let original = try XCTUnwrap(factory.sessions.last)
            let firstSample = Float(cycle % 8 + 1) / 16
            original.deliver([firstSample])

            // A route notification storm must still create only one replacement.
            for _ in 0..<8 {
                clock.now += 0.03125
                original.sendConfigurationChange()
            }
            clock.now += CaptureRecoveryCoordinator.settleDelay
            XCTAssertFalse(try manager.recoverCaptureIfNeeded())
            XCTAssertEqual(original.stopCount, 1)
            clock.now += CaptureRecoveryCoordinator.postTeardownDelay
            XCTAssertTrue(try manager.recoverCaptureIfNeeded())

            let replacement = try XCTUnwrap(factory.sessions.last)
            original.deliver([-1])
            original.sendConfigurationChange()
            replacement.deliver([0.5])
            let stopped = manager.stopWithResult()
            XCTAssertEqual(stopped.samples, [firstSample, 0.5], "cycle \(cycle)")
            XCTAssertNil(stopped.terminalError)
            XCTAssertFalse(manager.isRecording)

            original.deliver([-1])
            replacement.deliver([-1])
            XCTAssertTrue(manager.stopWithResult().samples.isEmpty)
            XCTAssertEqual(factory.sessions.count, (cycle + 1) * 2)
        }
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
        XCTAssertTrue(factory.startPreferences.allSatisfy { $0 == .disabled })
    }

    func testOneHundredStoppedOrCancelledRetriesNeverRestartInTheNextDictation() throws {
        let clock = TestUptime()
        let outcomes: [FakeStartOutcome] = (0..<100).flatMap { _ in
            [.success, .failure(.engineFailed("synthetic route unavailable"))]
        }
        let factory = FakeAudioCaptureEngineFactory(outcomes: outcomes)
        let manager = AudioCaptureManager(
            voiceProcessing: .disabled,
            engineFactory: factory,
            uptime: { clock.now }
        )

        for cycle in 0..<100 {
            try manager.start()
            let original = try XCTUnwrap(factory.sessions.last)
            original.deliver([0.25])
            original.sendConfigurationChange()
            clock.now += CaptureRecoveryCoordinator.settleDelay
            XCTAssertFalse(try manager.recoverCaptureIfNeeded())
            clock.now += CaptureRecoveryCoordinator.postTeardownDelay
            XCTAssertFalse(try manager.recoverCaptureIfNeeded())
            XCTAssertTrue(manager.isRecording)

            if cycle.isMultiple(of: 2) {
                XCTAssertEqual(manager.stopWithResult().samples, [0.25])
            } else {
                manager.cancel()
                XCTAssertTrue(manager.stopWithResult().samples.isEmpty)
            }
            original.deliver([-1])
            original.sendConfigurationChange()
            clock.now += 100
            XCTAssertFalse(try manager.recoverCaptureIfNeeded())
            XCTAssertEqual(factory.startPreferences.count, (cycle + 1) * 2)
            XCTAssertTrue(manager.stopWithResult().samples.isEmpty)
        }

        try manager.start()
        try XCTUnwrap(factory.sessions.last).deliver([0.75])
        let fresh = manager.stopWithResult()
        XCTAssertEqual(fresh.samples, [0.75])
        XCTAssertNil(fresh.terminalError)
        XCTAssertEqual(factory.maximumActiveSessionCount, 1)
    }

    private func makeManager(
        clock: TestUptime,
        factory: FakeAudioCaptureEngineFactory
    ) -> AudioCaptureManager {
        AudioCaptureManager(
            voiceProcessing: .automatic,
            engineFactory: factory,
            uptime: { clock.now }
        )
    }
}

private final class TestUptime {
    var now: TimeInterval = 0
}

private enum FakeStartOutcome {
    case success
    case failure(AudioCaptureError)
}

private final class FakeAudioCaptureEngineFactory: AudioCaptureEngineStarting {
    private var outcomes: [FakeStartOutcome]
    private(set) var startPreferences: [VoiceProcessingPreference] = []
    private(set) var sessions: [FakeAudioCaptureEngineSession] = []
    private(set) var maximumActiveSessionCount = 0
    var beforeReturningSession: (() -> Void)?

    init(outcomes: [FakeStartOutcome]) {
        self.outcomes = outcomes
    }

    func start(
        preference: VoiceProcessingPreference,
        onSamples: @escaping ([Float], Float, Float) -> Void
    ) throws -> any AudioCaptureEngineSession {
        startPreferences.append(preference)
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        if case .failure(let error) = outcome {
            throw error
        }

        let session = FakeAudioCaptureEngineSession(
            activation: preference == .automatic
                ? .enabled
                : .disabledByPreference,
            onSamples: onSamples
        )
        sessions.append(session)
        maximumActiveSessionCount = max(
            maximumActiveSessionCount,
            sessions.filter { !$0.isStopped }.count
        )
        beforeReturningSession?()
        return session
    }
}

private final class FakeAudioCaptureEngineSession: AudioCaptureEngineSession {
    let activation: VoiceProcessingActivation
    let nativeSampleRate: Double = 48_000
    private let onSamples: ([Float], Float, Float) -> Void
    private var configurationHandler: (() -> Void)?
    private(set) var stopCount = 0
    private(set) var isStopped = false

    init(
        activation: VoiceProcessingActivation,
        onSamples: @escaping ([Float], Float, Float) -> Void
    ) {
        self.activation = activation
        self.onSamples = onSamples
    }

    func observeConfigurationChanges(_ handler: @escaping () -> Void) {
        configurationHandler = handler
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopCount += 1
    }

    func sendConfigurationChange() {
        configurationHandler?()
    }

    func deliver(_ samples: [Float]) {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        onSamples(samples, peak, peak)
    }
}
