import AppKit
import ApplicationServices
import XCTest

@testable import InsertionEngine
@testable import VoiceCore

private final class CountingPasteboardDataProvider: NSObject,
    NSPasteboardItemDataProvider
{
    private(set) var requestCount = 0

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestCount += 1
        item.setString("private existing clipboard", forType: type)
    }

    func reset() {
        requestCount = 0
    }
}

final class TextInserterTests: XCTestCase {
    func testAllowlistedAppWithoutFocusedElementNeverBlindPastes() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.tinyspeck.slackmacgap",
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("private text", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testAllowlistedSecureFieldNeverPastes() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            secureField: true
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("private text", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testAllowlistedNonSecureFieldUsesConfirmedPaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.hnc.Discord",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testUnverifiedPasteIsNeverReportedAsSuccess() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.hnc.Discord",
            pasteVerification: .rejected
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testPasteWithoutCaretVerificationIsAttemptedButNeverReportedAsSuccess() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            pasteVerification: .unavailable
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testNonAllowlistedAppStillPrefersAXInsertion() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(result.method, .accessibilitySelectedText)
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testKnownUnreliableSafariSkipsAXAndUsesConfirmedPaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testCodexSkipsAmbiguousAXAndUsesConfirmedPaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testPIDOnlyPasteRejectsDifferentFrontmostApplicationBeforeStaging() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            frontmostPID: 84
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testPIDOnlyPasteRevalidatesFrontmostApplicationAtEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            frontmostPIDBeforeGlobalPaste: 84
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testAXSetterAmbiguousOutcomeNeverFallsBackOrReportsSuccess() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            axInsertionVerification: .outcomeUnknown,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testAXVerificationTreatsUnchangedObservedStateAsUnknownAfterWrite() {
        XCTAssertEqual(
            AXInsertionVerification.evaluate(
                beforeRange: CFRange(location: 0, length: 0),
                afterRange: CFRange(location: 0, length: 0),
                beforeCharacterCount: 0,
                afterCharacterCount: 0,
                insertedUTF16Count: 5
            ),
            .outcomeUnknown
        )
    }

    func testAXPreflightRefusesEqualLengthSelectedReplacement() {
        XCTAssertFalse(
            AXInsertionVerification.canAttempt(
                beforeRange: CFRange(location: 4, length: 5),
                beforeCharacterCount: 12,
                insertedUTF16Count: 5
            )
        )
    }

    func testAXPreflightRefusesMissingCharacterCount() {
        XCTAssertFalse(
            AXInsertionVerification.canAttempt(
                beforeRange: CFRange(location: 4, length: 0),
                beforeCharacterCount: nil,
                insertedUTF16Count: 5
            )
        )
    }

    func testAXVerificationNeverConfirmsWithoutPostWriteCharacterCount() {
        XCTAssertEqual(
            AXInsertionVerification.evaluate(
                beforeRange: CFRange(location: 4, length: 0),
                afterRange: CFRange(location: 9, length: 0),
                beforeCharacterCount: 12,
                afterCharacterCount: nil,
                insertedUTF16Count: 5
            ),
            .outcomeUnknown
        )
    }

    func testAXVerificationConfirmsCollapsedCaretAndExactCountIncrease() {
        XCTAssertEqual(
            AXInsertionVerification.evaluate(
                beforeRange: CFRange(location: 4, length: 0),
                afterRange: CFRange(location: 9, length: 0),
                beforeCharacterCount: 12,
                afterCharacterCount: 17,
                insertedUTF16Count: 5
            ),
            .confirmed
        )
    }

    func testAXVerificationTreatsOverflowingEvidenceAsUnknown() {
        XCTAssertEqual(
            AXInsertionVerification.evaluate(
                beforeRange: CFRange(location: Int.max, length: 0),
                afterRange: CFRange(location: Int.max, length: 0),
                beforeCharacterCount: Int.max,
                afterCharacterCount: Int.max,
                insertedUTF16Count: 1
            ),
            .outcomeUnknown
        )
    }

    func testPasteVerificationTreatsOverflowingEvidenceAsUnavailable() {
        XCTAssertEqual(
            PasteVerification.evaluate(
                before: CFRange(location: Int.max, length: 0),
                after: CFRange(location: Int.max, length: 0),
                insertedUTF16Count: 1
            ),
            .unavailable
        )
    }

    func testFocusLockRejectsDifferentFrontmostApplicationBeforeAnyWrite() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 84,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRejectsRelaunchedOrReplacedPIDIdentity() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.example.OtherApp",
            appName: "Other App",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockStillFailsClosedForSecureField() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testPreflightRejectsSecureFieldBeforeAnyWrite() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.preflight(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testPreflightRejectsMissingFocusedElementBeforeAnyWrite() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.preflight(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testPreflightAcceptsStableNonSecureFieldWithoutWriting() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        try inserter.preflight(lock)

        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExplicitSecureBoundaryProbeRetainsNoTargetAndPerformsNoWrite() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertTrue(inserter.isExplicitSecureFieldFocused(for: lock))
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExplicitSecureBoundaryProbeTreatsUnknownAsNonAuthorizing() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            dynamicSecureAlwaysUnknown: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertFalse(inserter.isExplicitSecureFieldFocused(for: lock))
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testMissingFieldDoesNotBlockCaptureButStillRefusesDeliveryPreflight() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        // A renderer may temporarily publish no focused control. This must not
        // prevent local recording or authorize delivery to an unknown target.
        XCTAssertFalse(inserter.isExplicitSecureFieldFocused(for: lock))
        XCTAssertThrowsError(try inserter.preflight(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCaptureTargetRejectsMissingFocusedControl() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.captureTarget(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
    }

    func testCaptureTargetRejectsSecureFocusedControl() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true,
            selectedTextRangeSupported: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.captureTarget(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
    }

    func testCaptureTargetRejectsUnverifiableSecurityMetadata() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            dynamicSecureAlwaysUnknown: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.captureTarget(lock)) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .targetSecurityUnverifiable
            )
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRecoversOneStableSameApplicationControlRefresh() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 1,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        let target =
            try await inserter
            .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertGreaterThanOrEqual(environment.focusedElementReadCount, 2)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testOrdinaryCodexCaptureRefusesContinuousFocusedProxyChurn() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementAlternatesOnEveryRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("capture must wait for one coherent stable observation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }

        XCTAssertGreaterThan(environment.focusedElementReadCount, 20)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryClaudeCaptureRefusesContinuousFocusedProxyChurn() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            focusedElementAlternatesOnEveryRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("capture must wait for one coherent stable observation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }

        XCTAssertGreaterThan(environment.focusedElementReadCount, 20)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureUsesApplicationFocusWhenChildFocusedIsFalseOrUnavailable()
        async throws
    {
        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]
        let childFocusedStates: [Bool?] = [false, nil]

        for application in applications {
            for childFocused in childFocusedStates {
                let environment = TestInsertionEnvironment(
                    bundleID: application.bundleID,
                    appName: application.appName,
                    currentElementFocusResult: childFocused
                )
                let inserter = TextInserter(environment: environment)
                let lock = InsertionFocusLock(
                    processIdentifier: 42,
                    bundleIdentifier: application.bundleID,
                    appName: application.appName
                )!

                _ =
                    try await inserter
                    .captureTargetRecoveringFromSameApplicationFieldDrift(lock)

                XCTAssertEqual(environment.axInsertionAttempts, 0)
                XCTAssertEqual(environment.pastePreparationAttempts, 0)
                XCTAssertEqual(environment.pasteAttempts, 0)
            }
        }
    }

    @MainActor
    func testOrdinaryDynamicCaptureRetriesTransientMissingApplicationFocus() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementUnavailableReadCount: 2,
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertGreaterThanOrEqual(environment.focusedElementReadCount, 4)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureRetriesMissingDescriptorPastLegacyWindow() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil,
            dynamicControlDescriptorUnavailableReadCount: 22
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 22)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureAdoptsOnlyCoherentReplacementAtDelivery() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 3,
            alternateSemanticIdentifier: "replacement-composer",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertGreaterThan(environment.focusedElementReadCount, 6)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testOrdinaryDynamicCaptureRequiresTextCapabilityWithoutRangeValue() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRangeSupported: false,
            selectedTextRange: nil
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a persistent non-text control must fail before delivery")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertGreaterThan(
            environment.selectedTextRangeCapabilityReadCount,
            20
        )
        XCTAssertLessThanOrEqual(
            environment.selectedTextRangeCapabilityReadCount,
            80
        )
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureTreatsSecureTransitionAfterCapabilityAsTerminal() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusSwitchesToSecureAlternateAfterCapabilityReadCount: 0,
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a secure transition must fail before delivery")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.selectedTextRangeCapabilityReadCount, 1)
        XCTAssertFalse(environment.originalElementIsSecure)
        XCTAssertTrue(environment.alternateElementIsSecure)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureRefusesSecondSecureTransitionDuringFinalReplacementValidation()
        async
    {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil,
            focusedElementChangesAfterReadCount: 8,
            focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount: 10
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a second secure transition must fail before delivery")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertTrue(environment.secondAlternateElementIsSecure)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureHoldReleaseCancelsBoundedFocusPolling() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementAvailable: false
        )
        var captureLeaseIsValid = true
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in captureLeaseIsValid = false }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(
                lock,
                shouldContinue: { captureLeaseIsValid }
            )
            XCTFail("released hold must cancel logical-target polling")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertGreaterThan(environment.focusedElementReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureFlushesQueuedHoldReleaseAfterDescriptorRead() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            queueCaptureLeaseInvalidationAfterDescriptorRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(
                lock,
                shouldContinue: { environment.captureLeaseIsValid }
            )
            XCTFail("queued hold release must invalidate capture before return")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 0)
        XCTAssertFalse(environment.captureLeaseIsValid)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureKeepsExactControlBehindOwnHomeWindow() async throws {
        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]

        for application in applications {
            let environment = TestInsertionEnvironment(
                bundleID: application.bundleID,
                appName: application.appName,
                frontmostPID: 999,
                ownPID: 999,
                selectedTextRange: nil
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: application.bundleID,
                appName: application.appName
            )!

            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)

            XCTAssertEqual(environment.focusedElementReadCount, 4)
            XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
            XCTAssertEqual(environment.pastePreparationAttempts, 0)
            XCTAssertEqual(environment.pasteAttempts, 0)
        }
    }

    @MainActor
    func testOrdinaryHomeCaptureReactivatesFrozenCodexAtDelivery() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRange: CFRange(location: 12, length: 0)
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertGreaterThan(environment.focusedElementReadCount, 0)
        XCTAssertGreaterThan(environment.selectedTextRangeCapabilityReadCount, 0)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureWaitsToReadAXUntilTargetIsFrontmost() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementUnavailableUnlessTargetFrontmost: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.preCaptureActivationRequests, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertGreaterThan(environment.focusedElementReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureAlreadyFrontmostNeverRequestsActivation() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 42
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRefusesInitiallyUnrelatedFrontmostAppWithoutActivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 84,
            ownPID: 999
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("an unrelated frontmost app must never be overridden")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesPreexistingGenerationMismatchWithoutActivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            currentActivationGeneration: 8
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 7
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a stale generation must fail before activation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesPreexistingIdentityMismatchWithoutActivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.example.replacement",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a replaced PID identity must fail before activation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureFlushesQueuedExternalActivationBeforeRequest() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            currentActivationGeneration: 7
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in
                environment.showExternalApplication(
                    processIdentifier: 84,
                    activationGeneration: 8
                )
            }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 7
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("queued external activation must win before our request")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureFlushesQueuedHoldReleaseAfterDescriptorRead() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            queueCaptureLeaseInvalidationAfterDescriptorRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(
                lock,
                shouldContinue: { environment.captureLeaseIsValid }
            )
            XCTFail("queued hold release must invalidate Home capture")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 0)
        XCTAssertFalse(environment.captureLeaseIsValid)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureFlushesQueuedActivationAfterDescriptorRead() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            queueExternalActivationAfterDescriptorRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("queued external activation must invalidate Home capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 0)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 84)
        XCTAssertEqual(environment.currentActivationGeneration(), 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureUsesObservedFocusWhenActivationAPIReportsFalse() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            frontmostPIDAfterFailedActivation: 42,
            activationSucceeds: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureSupportsStableNonAllowlistedTextTarget() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRange: CFRange(location: 3, length: 0)
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertGreaterThan(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesRejectedActivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a refused activation must fail before capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureTimesOutIfTargetNeverBecomesFrontmost() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            activationChangesFrontmost: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a target that never becomes frontmost must time out")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesInterveningExternalApplication() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            frontmostPIDAfterActivation: 84
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("an unrelated frontmost app must fail before capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 84)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesActivationGenerationChange() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            currentActivationGeneration: 7,
            activationGenerationAfterActivation: 8
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 7
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("an intervening activation generation must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesBundleIdentityChangeDuringActivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            bundleIDAfterActivation: "com.example.replacement"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a replaced PID identity must fail before capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesSecureFieldAfterReactivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            secureFieldAfterActivation: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("a secure field must fail before capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRetriesTransientMissingFocusedElement() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementUnavailableReadCount: 2
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThanOrEqual(environment.focusedElementReadCount, 3)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRetriesMissingDescriptorPastLegacyWindow() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRange: nil,
            dynamicControlDescriptorUnavailableReadCount: 22
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 22)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureAdoptsOnlyCoherentReplacementAtDelivery() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementChangesAfterReadCount: 3,
            alternateSemanticIdentifier: "replacement-composer"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.focusedElementReadCount, 6)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureRefusesPersistentlyMissingFocusedElement() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("persistent missing focus evidence must fail before capture")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureDoesNotReadTransientlyMissingRange() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRangeUnavailableReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureAcceptsPersistentlyMissingRangeValue() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.selectedTextRangeCapabilityReadCount, 0)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureAcceptsNoncollapsedSelection() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            selectedTextRange: CFRange(location: 4, length: 2)
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertGreaterThan(environment.selectedTextRangeCapabilityReadCount, 0)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureCancellationDuringActivationStopsBeforeReadiness() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            activationDelayNanoseconds: 200_000_000
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let task = Task { @MainActor in
            try await inserter.prepareTargetForOrdinaryCapture(lock)
        }

        for _ in 0..<100 where environment.activationAttempts == 0 {
            await Task.yield()
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled Home recovery must stop before capture readiness")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryHomeCaptureHoldReleaseDuringYieldCancelsBeforeActivation() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999
        )
        var captureLeaseIsValid = true
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in captureLeaseIsValid = false }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(
                lock,
                shouldContinue: { captureLeaseIsValid }
            )
            XCTFail("released hold trigger must cancel before activation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testStrictCaptureBehindHomeNeverUsesOrdinaryReactivation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementAvailable: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.captureTarget(lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryDynamicCaptureDoesNotFollowProxyChurnBehindOwnHomeWindow() async {
        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]

        for application in applications {
            let environment = TestInsertionEnvironment(
                bundleID: application.bundleID,
                appName: application.appName,
                frontmostPID: 999,
                ownPID: 999,
                focusedElementAlternatesOnEveryRead: true
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: application.bundleID,
                appName: application.appName
            )!

            do {
                _ =
                    try await inserter
                    .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
                XCTFail("own-Home capture must retain exact-control semantics")
            } catch {
                XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
            }
            XCTAssertEqual(environment.focusedElementReadCount, 8)
            XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
            XCTAssertEqual(environment.pastePreparationAttempts, 0)
            XCTAssertEqual(environment.pasteAttempts, 0)
        }
    }

    @MainActor
    func testOrdinaryClaudeCaptureAcceptsMissingRangeValue() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        _ =
            try await inserter
            .captureTargetRecoveringFromSameApplicationFieldDrift(lock)

        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertGreaterThan(environment.selectedTextRangeCapabilityReadCount, 0)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryClaudeCaptureAcceptsNoncollapsedSelection() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedTextRange: CFRange(location: 4, length: 2)
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        _ =
            try await inserter
            .captureTargetRecoveringFromSameApplicationFieldDrift(lock)

        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryNonCodexCaptureStillRefusesContinuousControlChurn() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            focusedElementAlternatesOnEveryRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("non-allowlisted control churn must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.focusedElementReadCount, 8)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRefusesActivationGenerationDriftBeforeRetry() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 1,
            activationGenerationChangeReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("an intervening activation must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.focusedElementReadCount, 2)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRefusesActivationDuringLogicalObservation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 1,
            activationGenerationChangesAfterGenerationReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("an activation during the retry suspension must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertGreaterThan(environment.activationGenerationReadCount, 1)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRefusesActivationDuringReplacementValidation() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 1,
            activationGenerationChangesAfterGenerationReadCount: 3
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("an activation during replacement validation must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertGreaterThanOrEqual(environment.focusedElementReadCount, 1)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureRefusesSecureReplacementWithoutRetrying() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementChangesAfterReadCount: 1,
            secureFieldAfterFocusedElementReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("a secure replacement must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.focusedElementReadCount, 2)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCaptureBoundedRetriesMissingAccessibilityTarget() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementAvailable: false
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("an unverifiable target must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertGreaterThan(environment.focusedElementReadCount, 20)
        XCTAssertLessThanOrEqual(environment.focusedElementReadCount, 80)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryRecoversTransientRangeBeforeOneEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRangeUnavailableReadCount: 1,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)

        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertGreaterThanOrEqual(environment.selectedTextRangeReadCount, 3)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryPersistentRangeAbsencePostsNoEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary(
                "reviewed text",
                into: target
            )
            XCTFail("a persistent missing range must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.selectedTextRangeReadCount, 20)
        XCTAssertEqual(environment.pasteAttempts, 0)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinaryFinalRangeLossAfterAsyncEvidencePostsNoEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRangeUnavailableBeforePasteboardStaging: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("stale pre-stage range evidence must not reach Cmd+V")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryReplacesSelectionWithOneVerifiedEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedTextRange: CFRange(location: 4, length: 6),
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)

        let result = try await inserter.insertOrdinary(
            "replacement",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryRefusesContinuousEventBoundaryProxyChurn() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        environment.enableFocusedElementAlternation()

        do {
            _ = try await inserter.insertOrdinary(
                "reviewed text",
                into: target
            )
            XCTFail("a permanently unstable event snapshot must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryFollowsStableCurrentSameSignatureComposer() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedRangeMutationAtEventResolver: .focusToNonsecureField,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.eventResolverRangeMutationCount, 1)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryRefusesDifferentWindowBeforeStaging() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedRangeMutationAtEventResolver: .focusToNonsecureField,
            alternateUsesDifferentWindow: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("a different owning window must not inherit the transcript")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinaryDeliveryRefusesDifferentSameWindowSemanticField() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedRangeMutationAtEventResolver: .focusToNonsecureField,
            alternateSemanticIdentifier: "search"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("a different field in the same window must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testLogicalOrdinarySecureFocusTransitionBeforeStagingIsTerminal() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedRangeMutationAtEventResolver: .focusToSecureField
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("a current secure field must be terminal")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertFalse(environment.originalElementIsSecure)
        XCTAssertTrue(environment.alternateElementIsSecure)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testDynamicSecurityUnknownRecoversWithinPreflightBound() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            dynamicSecureUnknownReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        _ = try await inserter.prepareTargetForOrdinaryCapture(lock)

        XCTAssertGreaterThanOrEqual(
            environment.dynamicSecureClassificationReadCount,
            4
        )
        XCTAssertEqual(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testPersistentUnknownDynamicSecurityFailsSensitiveBeforeDelivery() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            dynamicSecureAlwaysUnknown: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("unknown security must fail closed")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .targetSecurityUnverifiable
            )
            XCTAssertTrue(
                (error as? InsertionError)?
                    .requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testTransientUnknownSecurityRecoversBeforeOneEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            dynamicSecureUnknownReadCountBeforeGlobalPaste: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testPersistentUnknownSecurityBeforeEventNeverStagesOrPosts() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            dynamicSecureAlwaysUnknownBeforeGlobalPaste: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("unknown event security must fail closed")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .targetSecurityUnverifiable
            )
            XCTAssertTrue(
                (error as? InsertionError)?
                    .requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testDynamicCaptureRefusesRangeCapableNonTextControl() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRangeSupported: true,
            dynamicControlDescriptorAvailable: false
        )
        let inserter = TextInserter(
            environment: environment,
            captureReadinessDelay: { _ in }
        )
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        do {
            _ = try await inserter.prepareTargetForOrdinaryCapture(lock)
            XCTFail("range support alone must not admit a non-text control")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertGreaterThan(environment.dynamicControlDescriptorReadCount, 20)
        XCTAssertLessThanOrEqual(
            environment.dynamicControlDescriptorReadCount,
            80
        )
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    @MainActor
    func testCancellationDuringPreEventReadinessPostsNoEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let insertion = Task {
            try await inserter.insertOrdinary("private text", into: target)
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        insertion.cancel()
        do {
            _ = try await insertion.value
            XCTFail("cancellation must stop pre-event readiness")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testReinsertGatePreEventCancellationReleasesWithoutEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let gate = ReinsertTaskGate()
        let lease = try XCTUnwrap(gate.begin())
        var observedError: Error?

        let insertion = Task { @MainActor in
            defer { gate.finish(lease) }
            do {
                _ = try await inserter.insertOrdinary(
                    "private text",
                    into: target,
                    commitDelivery: {
                        guard gate.commitDelivery(lease) else {
                            throw CancellationError()
                        }
                    }
                )
            } catch {
                observedError = error
            }
        }
        gate.attach(insertion, to: lease)

        for _ in 0..<40 where environment.selectedTextRangeReadCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(environment.selectedTextRangeReadCount, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
        XCTAssertTrue(gate.cancelAll())
        XCTAssertTrue(gate.hasPendingTask)
        XCTAssertNil(gate.begin())

        await insertion.value

        XCTAssertTrue(observedError is CancellationError)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
        XCTAssertFalse(gate.hasPendingTask)
        let replacement = try XCTUnwrap(gate.begin())
        gate.finish(replacement)
    }

    @MainActor
    func testCancelledReinsertCommitPreventsExactAXSetter() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        let gate = ReinsertTaskGate()
        let lease = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.cancelAll())

        do {
            _ = try await inserter.insertOrdinary(
                "private text",
                into: target,
                commitDelivery: {
                    guard gate.commitDelivery(lease) else {
                        throw CancellationError()
                    }
                }
            )
            XCTFail("a cancelled delivery commit must refuse the AX setter")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
        gate.finish(lease)
    }

    @MainActor
    func testCancelledReinsertCommitPreventsExactPasteEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)
        let gate = ReinsertTaskGate()
        let lease = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.cancelAll())

        do {
            _ = try await inserter.insertOrdinary(
                "private text",
                into: target,
                commitDelivery: {
                    guard gate.commitDelivery(lease) else {
                        throw CancellationError()
                    }
                }
            )
            XCTFail("a cancelled delivery commit must refuse Cmd+V")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
        gate.finish(lease)
    }

    @MainActor
    func testReinsertGatePostEventCancellationBlocksRetryUntilUnknownReceipt() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            postPasteMissingFocusedElementAttempts: 64,
            pasteVerification: .confirmed,
            postPasteVerificationDelayNanoseconds: 5_000_000
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let gate = ReinsertTaskGate()
        let lease = try XCTUnwrap(gate.begin())
        var observedError: InsertionError?
        var terminalCount = 0

        let insertion = Task { @MainActor in
            defer {
                gate.finish(lease)
                terminalCount += 1
            }
            do {
                _ = try await inserter.insertOrdinary(
                    "private text",
                    into: target,
                    commitDelivery: {
                        guard gate.commitDelivery(lease) else {
                            throw CancellationError()
                        }
                    }
                )
            } catch {
                observedError = error as? InsertionError
            }
        }
        gate.attach(insertion, to: lease)

        for _ in 0..<80 where environment.pasteAttempts == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertTrue(gate.deliveryWasCommitted(for: lease))

        XCTAssertTrue(gate.cancelAll())
        XCTAssertEqual(terminalCount, 0)
        XCTAssertTrue(gate.hasPendingTask)
        XCTAssertNil(gate.begin(), "a second reinsert must remain blocked")
        XCTAssertEqual(environment.pasteAttempts, 1)

        await insertion.value

        XCTAssertEqual(observedError, .insertionUnverified)
        XCTAssertTrue(observedError?.requiresCancellationSafetyNotice == true)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertFalse(gate.hasPendingTask)
    }

    @MainActor
    func testAwayBackGenerationDuringPreEventWaitPostsNoEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            selectedTextRange: nil
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let insertion = Task {
            try await inserter.insertOrdinary("private text", into: target)
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        environment.showExternalApplication(
            processIdentifier: 84,
            activationGeneration: 1
        )
        environment.showExternalApplication(
            processIdentifier: 42,
            activationGeneration: 1
        )
        do {
            _ = try await insertion.value
            XCTFail("an away/back generation change must remain terminal")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testQueuedActivationCallbackRunsBeforeClipboardStageAndEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            queueActivationGenerationChangeAfterEventEvidence: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("queued activation must be observed before staging")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testCancellationDuringReceiptNeverRepastes() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            postPasteMissingFocusedElementAttempts: 4,
            pasteVerification: .confirmed,
            postPasteVerificationDelayNanoseconds: 50_000_000
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        let insertion = Task {
            try await inserter.insertOrdinary("private text", into: target)
        }

        for _ in 0..<20 where environment.pasteAttempts == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        insertion.cancel()
        do {
            _ = try await insertion.value
            XCTFail("a cancelled receipt must not report success")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testCurrentTargetDeliveryWaitsForLeaseBeforeCapturingField() async throws {
        let holdingEnvironment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            postPasteMissingFocusedElementAttempts: 1,
            pasteVerification: .confirmed,
            postPasteVerificationDelayNanoseconds: 50_000_000
        )
        let holdingInserter = TextInserter(environment: holdingEnvironment)
        let holdingLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let holdingTarget =
            try await holdingInserter
            .prepareTargetForOrdinaryCapture(holdingLock)
        let holdingInsertion = Task { @MainActor in
            try await holdingInserter.insertOrdinary(
                "holding transcript",
                into: holdingTarget
            )
        }
        for _ in 0..<40 where holdingEnvironment.pasteAttempts == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(holdingEnvironment.pasteAttempts, 1)

        let waitingEnvironment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmed
        )
        let waitingInserter = TextInserter(environment: waitingEnvironment)
        let waitingLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let waitingInsertion = Task { @MainActor in
            try await waitingInserter.insertOrdinaryAtCurrentTarget(
                "waiting transcript",
                into: waitingLock
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(waitingEnvironment.dynamicControlDescriptorReadCount, 0)
        XCTAssertEqual(waitingEnvironment.pastePreparationAttempts, 0)

        _ = try await holdingInsertion.value
        let delivery = try await waitingInsertion.value
        XCTAssertEqual(delivery.result.method, .pasteboard)
        XCTAssertGreaterThan(
            waitingEnvironment.dynamicControlDescriptorReadCount,
            0
        )
        XCTAssertEqual(waitingEnvironment.pasteAttempts, 1)
    }

    @MainActor
    func testCurrentTargetDeliveryReactivatesHomeTargetThenInsertsOnce() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            frontmostPIDAfterActivation: 42,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        let delivery = try await inserter.insertOrdinaryAtCurrentTarget(
            "reviewed text",
            into: lock
        )

        XCTAssertEqual(delivery.result.method, .pasteboard)
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testCurrentTargetDeliveryRefusesSecureFieldBeforeAnyWrite() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        do {
            _ = try await inserter.insertOrdinaryAtCurrentTarget(
                "private text",
                into: lock
            )
            XCTFail("a secure delivery target must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testDynamicAndExactOrdinaryPasteTransactionsSerialize() async throws {
        let dynamicEnvironment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            postPasteMissingFocusedElementAttempts: 1,
            pasteVerification: .confirmed,
            postPasteVerificationDelayNanoseconds: 50_000_000
        )
        let dynamicInserter = TextInserter(environment: dynamicEnvironment)
        let dynamicLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let dynamicTarget =
            try await dynamicInserter
            .prepareTargetForOrdinaryCapture(dynamicLock)

        let exactEnvironment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            pasteVerification: .confirmed
        )
        let exactInserter = TextInserter(environment: exactEnvironment)
        let exactLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let exactTarget = try exactInserter.captureTarget(exactLock)

        let dynamicInsertion = Task { @MainActor in
            try await dynamicInserter.insertOrdinary(
                "first transcript",
                into: dynamicTarget
            )
        }
        for _ in 0..<40 where dynamicEnvironment.pasteAttempts == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(dynamicEnvironment.pasteAttempts, 1)

        XCTAssertThrowsError(
            try exactInserter.insert("direct sync transcript", into: exactTarget)
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(exactEnvironment.pastePreparationAttempts, 0)
        XCTAssertEqual(exactEnvironment.pasteAttempts, 0)

        let exactInsertion = Task { @MainActor in
            try await exactInserter.insertOrdinary(
                "second transcript",
                into: exactTarget
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(exactEnvironment.pastePreparationAttempts, 0)
        XCTAssertEqual(exactEnvironment.pasteAttempts, 0)

        _ = try await dynamicInsertion.value
        _ = try await exactInsertion.value
        XCTAssertEqual(dynamicEnvironment.pasteAttempts, 1)
        XCTAssertEqual(exactEnvironment.pasteAttempts, 1)
    }

    @MainActor
    func testCancellationWhileWaitingForPasteTransactionPostsNothing() async throws {
        let holdingEnvironment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            postPasteMissingFocusedElementAttempts: 1,
            pasteVerification: .confirmed,
            postPasteVerificationDelayNanoseconds: 50_000_000
        )
        let holdingInserter = TextInserter(environment: holdingEnvironment)
        let holdingLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let holdingTarget =
            try await holdingInserter
            .prepareTargetForOrdinaryCapture(holdingLock)

        let waitingEnvironment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            pasteVerification: .confirmed
        )
        let waitingInserter = TextInserter(environment: waitingEnvironment)
        let waitingLock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let waitingTarget = try waitingInserter.captureTarget(waitingLock)

        let holdingInsertion = Task { @MainActor in
            try await holdingInserter.insertOrdinary(
                "holding transcript",
                into: holdingTarget
            )
        }
        for _ in 0..<40 where holdingEnvironment.pasteAttempts == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(holdingEnvironment.pasteAttempts, 1)

        let waitingInsertion = Task { @MainActor in
            try await waitingInserter.insertOrdinary(
                "cancelled transcript",
                into: waitingTarget
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        waitingInsertion.cancel()
        do {
            _ = try await waitingInsertion.value
            XCTFail("a cancelled lease waiter must not insert")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(waitingEnvironment.pastePreparationAttempts, 0)
        XCTAssertEqual(waitingEnvironment.pasteAttempts, 0)
        _ = try await holdingInsertion.value
    }

    func testDynamicComposerSignatureIgnoresDeepAnonymousGroupChurn() {
        let anonymousGroup = DynamicControlSemanticSignature.Node(
            role: "AXGroup",
            subrole: nil,
            identifier: nil
        )
        let anchors = [
            DynamicControlSemanticSignature.Node(
                role: "AXScrollArea",
                subrole: nil,
                identifier: nil
            ),
            DynamicControlSemanticSignature.Node(
                role: "AXWebArea",
                subrole: nil,
                identifier: nil
            ),
        ]
        let codexDepth30 = DynamicControlSemanticSignature.normalizedComposer(
            leafSubrole: nil,
            leafIdentifier: nil,
            ancestors: Array(repeating: anonymousGroup, count: 30) + anchors
        )
        let claudeDepth29 = DynamicControlSemanticSignature.normalizedComposer(
            leafSubrole: nil,
            leafIdentifier: nil,
            ancestors: Array(repeating: anonymousGroup, count: 29) + anchors
        )

        XCTAssertEqual(codexDepth30, claudeDepth29)
        XCTAssertEqual(codexDepth30.ancestors, anchors)
    }

    func testDynamicComposerSignatureRetainsLandmarkSubroleAnchor() {
        let landmark = DynamicControlSemanticSignature.Node(
            role: "AXGroup",
            subrole: "AXLandmarkMain",
            identifier: nil
        )

        let signature = DynamicControlSemanticSignature.normalizedComposer(
            leafSubrole: nil,
            leafIdentifier: nil,
            ancestors: [landmark]
        )

        XCTAssertEqual(signature.ancestors, [landmark])
    }

    @MainActor
    func testFinalSecurityReadReacquiresSecureFocusBeforeEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusSwitchesToSecureAlternateDuringFinalEventSecurityRead: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("focus changed during final security read must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertTrue(environment.alternateElementIsSecure)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testPostEventSecureTransitionReportsSensitiveUnknownOutcome() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            secureFieldBeforePostPasteVerification: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("post-event secure state must never claim no delivery")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveInsertionUnverified
            )
            XCTAssertTrue(
                (error as? InsertionError)?
                    .requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    func testDynamicTextLeafClassificationKeepsUnreadableSiblingUnknown() {
        XCTAssertEqual(
            dynamicEditableLeafEligibility(
                roleReadSucceeded: true,
                role: "AXTextArea",
                selectedTextRangeSettable: nil,
                characterCount: 0
            ),
            .unknown
        )
        XCTAssertEqual(
            dynamicEditableLeafEligibility(
                roleReadSucceeded: true,
                role: "AXTextArea",
                selectedTextRangeSettable: true,
                characterCount: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            dynamicEditableLeafEligibility(
                roleReadSucceeded: true,
                role: "AXTextArea",
                selectedTextRangeSettable: false,
                characterCount: 0
            ),
            .ineligible
        )
        XCTAssertEqual(
            dynamicEditableLeafEligibility(
                roleReadSucceeded: true,
                role: "AXButton",
                selectedTextRangeSettable: nil,
                characterCount: nil
            ),
            .ineligible
        )
    }

    func testDynamicSemanticMetadataDistinguishesAbsenceFromReadFailure() {
        XCTAssertEqual(
            dynamicSemanticStringObservation(
                status: .noValue,
                value: nil
            ),
            .value(nil)
        )
        XCTAssertEqual(
            dynamicSemanticStringObservation(
                status: .attributeUnsupported,
                value: nil
            ),
            .value(nil)
        )
        XCTAssertEqual(
            dynamicSemanticStringObservation(
                status: .cannotComplete,
                value: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            dynamicSemanticStringObservation(
                status: .success,
                value: "composer" as CFString
            ),
            .value("composer")
        )
    }

    @MainActor
    func testLogicalOrdinaryDeliveryTreatsFinalPolicyTransitionsAsTerminal() async throws {
        let cases: [(TestInsertionEnvironment, InsertionError)] = [
            (
                TestInsertionEnvironment(
                    bundleID: "com.openai.codex",
                    appName: "Codex",
                    secureFieldBeforeGlobalPaste: true
                ),
                .secureField
            ),
            (
                TestInsertionEnvironment(
                    bundleID: "com.openai.codex",
                    appName: "Codex",
                    bundleIDBeforeGlobalPaste: "com.example.replacement"
                ),
                .focusChanged
            ),
            (
                TestInsertionEnvironment(
                    bundleID: "com.openai.codex",
                    appName: "Codex",
                    frontmostPIDBeforeGlobalPaste: 84
                ),
                .focusChanged
            ),
            (
                TestInsertionEnvironment(
                    bundleID: "com.openai.codex",
                    appName: "Codex",
                    activationGenerationBeforeGlobalPaste: 1
                ),
                .focusChanged
            ),
        ]

        for (environment, expectedError) in cases {
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "com.openai.codex",
                appName: "Codex",
                activationGeneration: 0
            )!
            let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

            do {
                _ = try await inserter.insertOrdinary(
                    "private text",
                    into: target
                )
                XCTFail("a final policy transition must fail closed")
            } catch {
                XCTAssertEqual(error as? InsertionError, expectedError)
            }
            XCTAssertEqual(environment.pasteAttempts, 0)
            XCTAssertEqual(environment.postPasteVerificationAttempts, 0)
        }
    }

    @MainActor
    func testLogicalOrdinaryTargetRestoresFromOwnHomeBeforeOneEvent() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        environment.showOwnWindow(afterActivationGeneration: 0)

        let restored =
            try await inserter
            .restoreFocusForOrdinaryDictation(to: target)
        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: restored
        )

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testHomeFrontmostReinsertCapturesLogicalTargetBeforeProxyRemount() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementUnavailableUnlessTargetFrontmost: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        var target = try await inserter.prepareTargetForOrdinaryCapture(lock)
        XCTAssertEqual(environment.preCaptureActivationRequests, 1)
        environment.focusAlternateControl()
        target = try await inserter.restoreFocusForOrdinaryDictation(to: target)
        let result = try await inserter.insertOrdinary(
            "history transcript",
            into: target
        )

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testCodexCompatibilityContractRefusesContinuousProxyChurn() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementAlternatesOnEveryRead: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("reviewed text", into: lock)) {
            XCTAssertEqual($0 as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeApplicationContractDeliversThroughComposerRemount() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            focusedElementChangesBeforeGlobalPaste: true,
            postPasteMissingFocusedElementAttempts: 1,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        let result = try inserter.insert("reviewed text", into: lock)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 2)
        XCTAssertEqual(
            environment.selectedTextRangeReadCount,
            2,
            "dynamic transport must consume resolver evidence without another range read"
        )
    }

    func testClaudePostPastePersistentRangeAbsenceIsUnverifiedAfterOneEvent() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            postPasteMissingSelectedTextRangeAttempts: 4,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        XCTAssertThrowsError(try inserter.insert("reviewed text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 4)
    }

    @MainActor
    func testOrdinaryCodexKeepsFixedReceiptBehindOwnOverlayWhenActivationIsRefused() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try inserter.captureTarget(lock)

        try await inserter.restoreFocus(to: target)
        let result = try await inserter.insertOrdinary(
            "reviewed text",
            into: target
        )

        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 0)
    }

    func testCodexPostPasteTransientMissingProxyCanStillConfirm() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            postPasteMissingFocusedElementAttempts: 1,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        let result = try inserter.insert("reviewed text", into: lock)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 2)
    }

    func testCodexPostPastePersistentMissingProxyRemainsUnverified() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            postPasteMissingFocusedElementAttempts: 4,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("reviewed text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 4)
    }

    func testCodexPostPasteSecureTransitionIsTerminalAndSensitive() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            secureFieldBeforePostPasteVerification: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .sensitiveInsertionUnverified)
            XCTAssertTrue((error as? InsertionError)?.requiresSensitiveContentDiscard == true)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    func testCodexPostPasteIdentityTransitionIsTerminal() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            bundleIDBeforePostPasteVerification: "com.example.replaced",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    func testCodexPostPasteFrontmostTransitionIsTerminalAndUnverified() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPIDBeforePostPasteVerification: 84,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
            XCTAssertFalse(
                (error as? InsertionError)?.requiresSensitiveContentDiscard
                    == true
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    func testCodexPostPasteGenerationTransitionIsTerminal() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            activationGenerationBeforePostPasteVerification: 1,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
    }

    func testCodexDynamicContractRequiresTargetFrontmost() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementAlternatesOnEveryRead: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCodexDynamicContractRefusesSecureFieldBeforeStaging() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            secureFieldBeforePasteboardStaging: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeDynamicContractRefusesSecureFieldBeforeStaging() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            secureFieldBeforePasteboardStaging: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeDynamicContractRefusesMissingRangeBeforeStaging() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedTextRangeUnavailableBeforePasteboardStaging: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeDynamicContractRefusesMissingRangeAtEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedTextRangeUnavailableBeforeGlobalPaste: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeEventResolverRevalidatesPolicyAfterItsRangeRead() {
        let cases: [(DynamicSelectedRangeReadMutation, InsertionError)] = [
            (.secureField, .secureField),
            (.applicationIdentity, .focusChanged),
            (.activationGeneration, .focusChanged),
            (.frontmostApplication, .focusChanged),
        ]

        for (mutation, expectedError) in cases {
            let environment = TestInsertionEnvironment(
                bundleID: "com.anthropic.claudefordesktop",
                appName: "Claude",
                selectedRangeMutationAtEventResolver: mutation
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "com.anthropic.claudefordesktop",
                appName: "Claude"
            )!

            XCTAssertThrowsError(
                try inserter.insert("private text", into: lock),
                "mutation: \(mutation.rawValue)"
            ) { error in
                XCTAssertEqual(
                    error as? InsertionError,
                    expectedError,
                    "mutation: \(mutation.rawValue)"
                )
            }
            XCTAssertEqual(
                environment.eventResolverRangeMutationCount,
                1,
                "mutation must occur during the event resolver's range read: "
                    + mutation.rawValue
            )
            XCTAssertEqual(
                environment.pasteAttempts,
                0,
                "no event may follow the range-read transition: " + mutation.rawValue
            )
        }
    }

    func testEventRangeReadReacquiresDistinctSecureFocusedControl() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            selectedRangeMutationAtEventResolver: .focusToSecureField
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        XCTAssertThrowsError(
            try inserter.insert("private text", into: lock)
        ) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertFalse(environment.originalElementIsSecure)
        XCTAssertTrue(environment.alternateElementIsSecure)
        XCTAssertEqual(environment.eventResolverRangeMutationCount, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testClaudeEventResolverRecoversTransientRangeAndAcceptsSelection() throws {
        for mutation in [
            DynamicSelectedRangeReadMutation.unavailableRange,
            .noncollapsedRange,
        ] {
            let environment = TestInsertionEnvironment(
                bundleID: "com.anthropic.claudefordesktop",
                appName: "Claude",
                selectedRangeMutationAtEventResolver: mutation,
                pasteVerification: .confirmed
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "com.anthropic.claudefordesktop",
                appName: "Claude"
            )!

            let result = try inserter.insert("private text", into: lock)

            XCTAssertEqual(result.method, .pasteboard)
            XCTAssertEqual(environment.eventResolverRangeMutationCount, 1)
            XCTAssertEqual(environment.pasteAttempts, 1)
        }
    }

    func testClaudePostPasteResolverTreatsRangeReadPolicyTransitionsAsTerminal() {
        let cases: [(DynamicSelectedRangeReadMutation, InsertionError)] = [
            (.secureField, .sensitiveInsertionUnverified),
            (.applicationIdentity, .insertionUnverified),
            (.activationGeneration, .insertionUnverified),
            (.frontmostApplication, .insertionUnverified),
        ]

        for (mutation, expectedError) in cases {
            let environment = TestInsertionEnvironment(
                bundleID: "com.anthropic.claudefordesktop",
                appName: "Claude",
                selectedRangeMutationAtPostPasteResolver: mutation,
                pasteVerification: .confirmed
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "com.anthropic.claudefordesktop",
                appName: "Claude"
            )!

            XCTAssertThrowsError(
                try inserter.insert("private text", into: lock),
                "mutation: \(mutation.rawValue)"
            ) { error in
                XCTAssertEqual(
                    error as? InsertionError,
                    expectedError,
                    "mutation: \(mutation.rawValue)"
                )
            }
            XCTAssertEqual(environment.pasteAttempts, 1)
            XCTAssertEqual(environment.postPasteVerificationAttempts, 1)
            XCTAssertEqual(
                environment.postPasteResolverRangeMutationCount,
                1,
                "mutation must occur during the receipt resolver's range read: "
                    + mutation.rawValue
            )
        }
    }

    func testClaudePostPasteResolverRetriesTransientRangeReadWindowsWithoutRepasting() throws {
        for mutation in [
            DynamicSelectedRangeReadMutation.noncollapsedRange,
            .unavailableRange,
        ] {
            let environment = TestInsertionEnvironment(
                bundleID: "com.anthropic.claudefordesktop",
                appName: "Claude",
                selectedRangeMutationAtPostPasteResolver: mutation,
                pasteVerification: .confirmed
            )
            let inserter = TextInserter(environment: environment)
            let lock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "com.anthropic.claudefordesktop",
                appName: "Claude"
            )!

            let result = try inserter.insert("reviewed text", into: lock)

            XCTAssertEqual(result.method, .pasteboard)
            XCTAssertEqual(environment.pasteAttempts, 1)
            XCTAssertEqual(environment.postPasteVerificationAttempts, 2)
            XCTAssertEqual(environment.postPasteResolverRangeMutationCount, 1)
        }
    }

    @MainActor
    func testOrdinaryClaudeCaptureRefusesSecureReplacement() async {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            focusedElementChangesAfterReadCount: 1,
            secureFieldAfterFocusedElementReadCount: 1
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!

        do {
            _ =
                try await inserter
                .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
            XCTFail("a secure replacement must fail before delivery")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testDynamicApplicationFocusContractAcceptsFalseOrUnavailableChildFocusedAttribute() throws
    {
        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]
        let childFocusedStates: [Bool?] = [false, nil]

        for application in applications {
            for childFocused in childFocusedStates {
                let environment = TestInsertionEnvironment(
                    bundleID: application.bundleID,
                    appName: application.appName,
                    currentElementFocusResult: childFocused,
                    pasteVerification: .confirmed
                )
                let inserter = TextInserter(environment: environment)
                let lock = InsertionFocusLock(
                    processIdentifier: 42,
                    bundleIdentifier: application.bundleID,
                    appName: application.appName
                )!

                let result = try inserter.insert("reviewed text", into: lock)

                XCTAssertEqual(result.method, .pasteboard)
                XCTAssertEqual(environment.axInsertionAttempts, 0)
                XCTAssertEqual(environment.pasteAttempts, 1)
            }
        }
    }

    func testDynamicApplicationFocusContractIgnoresChildFocusDropDuringRangeRead() throws {
        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]

        for application in applications {
            let eventEnvironment = TestInsertionEnvironment(
                bundleID: application.bundleID,
                appName: application.appName,
                selectedRangeMutationAtEventResolver: .focus,
                pasteVerification: .confirmed
            )
            let eventInserter = TextInserter(environment: eventEnvironment)
            let eventLock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: application.bundleID,
                appName: application.appName
            )!

            let eventResult = try eventInserter.insert("reviewed text", into: eventLock)

            XCTAssertEqual(eventResult.method, .pasteboard)
            XCTAssertEqual(eventEnvironment.eventResolverRangeMutationCount, 1)
            XCTAssertEqual(eventEnvironment.pasteAttempts, 1)

            let receiptEnvironment = TestInsertionEnvironment(
                bundleID: application.bundleID,
                appName: application.appName,
                selectedRangeMutationAtPostPasteResolver: .focus,
                pasteVerification: .confirmed
            )
            let receiptInserter = TextInserter(environment: receiptEnvironment)
            let receiptLock = InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: application.bundleID,
                appName: application.appName
            )!

            let receiptResult = try receiptInserter.insert(
                "reviewed text",
                into: receiptLock
            )

            XCTAssertEqual(receiptResult.method, .pasteboard)
            XCTAssertEqual(receiptEnvironment.postPasteResolverRangeMutationCount, 1)
            XCTAssertEqual(receiptEnvironment.pasteAttempts, 1)
        }
    }

    func testDynamicChildFocusToleranceDoesNotBypassOtherPolicyEvidence() {
        enum PolicyFailure: CaseIterable {
            case applicationIdentity
            case frontmostApplication
            case activationGeneration
            case secureField
            case missingApplicationFocusedElement
            case missingSelectedRange
        }

        let applications = [
            (bundleID: "com.openai.codex", appName: "Codex"),
            (bundleID: "com.anthropic.claudefordesktop", appName: "Claude"),
        ]
        let childFocusedStates: [Bool?] = [false, nil]

        for application in applications {
            for childFocused in childFocusedStates {
                for failure in PolicyFailure.allCases {
                    let environment: TestInsertionEnvironment
                    let expectedError: InsertionError
                    switch failure {
                    case .applicationIdentity:
                        environment = TestInsertionEnvironment(
                            bundleID: "com.example.replacement",
                            appName: application.appName,
                            currentElementFocusResult: childFocused
                        )
                        expectedError = .focusChanged
                    case .frontmostApplication:
                        environment = TestInsertionEnvironment(
                            bundleID: application.bundleID,
                            appName: application.appName,
                            frontmostPID: 84,
                            currentElementFocusResult: childFocused
                        )
                        expectedError = .focusChanged
                    case .activationGeneration:
                        environment = TestInsertionEnvironment(
                            bundleID: application.bundleID,
                            appName: application.appName,
                            currentActivationGeneration: 1,
                            currentElementFocusResult: childFocused
                        )
                        expectedError = .focusChanged
                    case .secureField:
                        environment = TestInsertionEnvironment(
                            bundleID: application.bundleID,
                            appName: application.appName,
                            currentElementFocusResult: childFocused,
                            secureField: true
                        )
                        expectedError = .secureField
                    case .missingApplicationFocusedElement:
                        environment = TestInsertionEnvironment(
                            bundleID: application.bundleID,
                            appName: application.appName,
                            focusedElementAvailable: false,
                            currentElementFocusResult: childFocused
                        )
                        expectedError = .insertionRejected
                    case .missingSelectedRange:
                        environment = TestInsertionEnvironment(
                            bundleID: application.bundleID,
                            appName: application.appName,
                            currentElementFocusResult: childFocused,
                            selectedTextRange: nil
                        )
                        expectedError = .insertionRejected
                    }

                    let inserter = TextInserter(environment: environment)
                    let lock = InsertionFocusLock(
                        processIdentifier: 42,
                        bundleIdentifier: application.bundleID,
                        appName: application.appName,
                        activationGeneration: 0
                    )!

                    XCTAssertThrowsError(
                        try inserter.insert("private text", into: lock),
                        "bundle=\(application.bundleID) child=\(String(describing: childFocused)) failure=\(failure)"
                    ) { error in
                        XCTAssertEqual(error as? InsertionError, expectedError)
                    }
                    XCTAssertEqual(environment.pasteAttempts, 0)
                }
            }
        }
    }

    func testCodexDynamicContractRefusesApplicationIdentityChangeAtEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            bundleIDBeforeGlobalPaste: "com.example.replaced"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCodexDynamicContractRefusesActivationGenerationChangeAtEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            focusedElementAlternatesOnEveryRead: true,
            activationGenerationChangesAfterGenerationReadCount: 2
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activationGeneration: 0
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedCodexInsertionKeepsExactControlAndNeverUsesDynamicPaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedClaudeInsertionKeepsExactControlAndNeverUsesDynamicPaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.anthropic.claudefordesktop",
            appName: "Claude",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedExactInsertionRejectsUnverifiableSecurityAtDelivery() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.makeSecurityUnverifiable()

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .targetSecurityUnverifiable
            )
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedExactInsertionRechecksFocusAfterFinalSecurityRead() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.armSecureAlternateFocusSwitch(afterSecurityReads: 3)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCodexRestoreRefreshesFrontmostNonSecureControl() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let original = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        let refreshed =
            try await inserter
            .restoreFocusForOrdinaryDictation(to: original)
        let result = try inserter.insert("reviewed text", into: refreshed)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testNonAllowlistedOrdinaryRestoreRefusesSameAppFieldDrift() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        do {
            _ = try await inserter.restoreFocusForOrdinaryDictation(to: target)
            XCTFail("an exact ordinary target must not follow another field")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testNonAllowlistedOrdinaryDeliveryRefusesSameAppFieldDrift() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        do {
            _ = try await inserter.insertOrdinary("private text", into: target)
            XCTFail("ordinary delivery must retain the exact captured field")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCodexReinsertSequenceRefusesContinuousProxyChurn() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!

        var target =
            try await inserter
            .captureTargetRecoveringFromSameApplicationFieldDrift(lock)
        target =
            try await inserter
            .restoreFocusForOrdinaryDictation(to: target)
        environment.enableFocusedElementAlternation()
        do {
            _ = try await inserter.insertOrdinary(
                "reviewed text",
                into: target
            )
            XCTFail("continuous event-boundary churn must fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    @MainActor
    func testOrdinaryCodexRestoreRefusesSecureReplacement() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let original = try inserter.captureTarget(lock)
        environment.focusAlternateControl()
        environment.makeFocusedControlSecure()

        do {
            _ = try await inserter.restoreFocusForOrdinaryDictation(to: original)
            XCTFail("secure replacement must be refused")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetAllowsExactControlAXInsertion() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(result.method, .accessibilitySelectedText)
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetAllowsExactControlPasteInsertion() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testCapturedTargetAllowsPidRoutedPasteBehindOwnHomeWindow() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteTargetPID, 42)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testCapturedTargetRefusesSecureTransitionBeforePidRoutedHomePaste() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            secureFieldBeforePasteboardStaging: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRefusesSecureTransitionAtPidRoutedHomeEventBoundary() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            secureFieldBeforeGlobalPaste: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRefusesSecureBackgroundControlWhenAppFocusIsUnavailable() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            secureFieldBeforePasteboardStaging: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        environment.omitApplicationFocusedElement(capturedControlFocus: true)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRefusesBackgroundControlDriftAtPidEventBoundary() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementChangesBeforeGlobalPaste: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        environment.omitApplicationFocusedElement(capturedControlFocus: true)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRefusesActivationGenerationDriftBehindOwnHomeWindow() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            currentActivationGeneration: 7,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            activationGeneration: 7
        )!
        let target = try inserter.captureTarget(lock)
        environment.showOwnWindow(afterActivationGeneration: 8)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRestoresFocusFromOwnHomeWindowBeforePaste() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            frontmostPID: 999,
            ownPID: 999,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        try await inserter.restoreFocus(to: target)
        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 42)
        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testCapturedTargetKeepsVerifiedOwnOverlayFallbackWhenActivationIsRefused() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        try await inserter.restoreFocus(to: target)
        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testCapturedTargetUsesExactControlFocusWhenBackgroundAppOmitsFocusedElement() async throws
    {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        environment.omitApplicationFocusedElement(capturedControlFocus: true)

        try await inserter.restoreFocus(to: target)
        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testCapturedTargetRefusesBackgroundControlWhenExactFocusIsUnverifiable() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        environment.omitApplicationFocusedElement(capturedControlFocus: false)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected unverifiable background control focus to fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetRefusesBackgroundControlWhenFocusedAttributeIsUnavailable() async throws
    {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        environment.omitApplicationFocusedElement(capturedControlFocus: nil)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected missing exact-control focus evidence to fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetKeepsVerifiedOwnOverlayFallbackWhenActivationNeverBecomesFrontmost()
        async throws
    {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationChangesFrontmost: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        try await inserter.restoreFocus(to: target)
        let result = try inserter.insert("reviewed text", into: target)

        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteTargetPID, 42)
    }

    func testCapturedTargetRejectsUnrelatedFrontmostAppWhenActivationIsRefused() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            frontmostPIDAfterFailedActivation: 84,
            activationSucceeds: false
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected an unrelated frontmost app to fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetRejectsSecureDriftWhenActivationIsRefused() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false,
            secureFieldAfterActivation: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected secure drift to fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetRejectsControlDriftWhenActivationIsRefused() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationSucceeds: false,
            focusedElementChangesAfterActivation: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected control drift to fail closed")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetCancellationDuringActivationAbortsBeforeInsertion() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            activationDelayNanoseconds: 200_000_000,
            activationSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)
        let task = Task { @MainActor in
            try await inserter.restoreFocus(to: target)
        }

        try await Task.sleep(nanoseconds: 75_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation to abort focus restoration")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(environment.frontmostProcessIdentifier(), 999)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetNeverRestoresFocusAfterInterveningActivation() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            ownPID: 999,
            currentActivationGeneration: 7,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            activationGeneration: 7
        )!
        let target = try inserter.captureTarget(lock)
        environment.showOwnWindow(afterActivationGeneration: 8)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected focus restoration to reject intervening activation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 0)
    }

    func testCapturedTargetRejectsActivationQueuedDuringFocusRestoration() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            currentActivationGeneration: 7,
            activationGenerationAfterActivation: 8
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            activationGeneration: 7
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected queued external activation to invalidate restoration")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetRejectsSecureTransitionDuringApplicationReactivation() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            frontmostPID: 999,
            ownPID: 999,
            secureFieldAfterActivation: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected focus restoration to reject a secure transition")
        } catch {
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetRejectsControlDriftDuringApplicationReactivation() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            frontmostPID: 999,
            ownPID: 999,
            focusedElementChangesAfterActivation: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        do {
            try await inserter.restoreFocus(to: target)
            XCTFail("Expected focus restoration to reject control drift")
        } catch {
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.activationAttempts, 1)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
    }

    func testCapturedTargetProhibitsPasteboardFallbackForSkipAXTarget() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetProhibitsPasteboardAfterPreWriteAXRefusal() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.preStagingValidationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedInsertionNeverPastesAfterPreWriteAXRefusal() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedInsertionTreatsAttemptedAmbiguousAXWriteAsUnknown() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionVerification: .outcomeUnknown,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteboardChangeCountReads, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetDefaultsToPasteboardAfterPreWriteAXRefusal() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: false,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        let result = try inserter.insert("ordinary text", into: target)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testCapturedTargetRejectsOwnOverlayWhenFrontmostTargetIsRequired() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 999,
            ownPID: 999,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetAllowsExactFrontmostControlWhenRequired() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        let result = try inserter.insert(
            "sensitive text",
            into: target,
            allowPasteboardFallback: false,
            requiresFrontmostTarget: true
        )

        XCTAssertEqual(result.method, .accessibilitySelectedText)
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteboardChangeCountReads, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExplicitForegroundCompatibilityContractCanResolveCurrentField() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        // The exact-control contract refuses, and reports the condition
        // distinctly from a target-application change.
        XCTAssertThrowsError(try inserter.insert("drifted", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }

        // The legacy foreground compatibility API has no exact capture token;
        // Product delivery never downgrades to this compatibility path.
        let result = try inserter.insert("drifted", into: target.focusLock)
        XCTAssertEqual(result.method, .accessibilitySelectedText)
    }

    func testSameAppFieldDriftRecoveryStillRefusesASecureField() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()
        environment.makeFocusedControlSecure()

        XCTAssertThrowsError(try inserter.insert("drifted", into: target.focusLock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFieldDriftAndApplicationChangeAreDistinctConditions() {
        XCTAssertNotEqual(InsertionError.targetFieldChanged, InsertionError.focusChanged)
        XCTAssertFalse(InsertionError.targetFieldChanged.requiresSensitiveContentDiscard)
    }

    func testCapturedTargetRejectsSameAppFieldDriftBeforeInsertion() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.focusAlternateControl()

        XCTAssertThrowsError(try inserter.insert("wrong field", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRejectsControlDisappearance() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.removeFocusedControl()

        XCTAssertThrowsError(try inserter.insert("missing field", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRejectsSecureTransition() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.makeFocusedControlSecure()

        XCTAssertThrowsError(try inserter.insert("credential", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRechecksExactControlAtDirectAXBoundary() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            focusedElementChangesBeforeAXWrite: true,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("wrong field", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedAXRefusesSecureFocusSwitchDuringEvidenceRead() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            selectedRangeMutationDuringExactAXEvidenceRead:
                .focusToSecureField,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "credential",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testProtectedAXRefusesNonsecureFocusSwitchDuringEvidenceRead() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            selectedRangeMutationDuringExactAXEvidenceRead:
                .focusToNonsecureField,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(
            try inserter.insert(
                "sensitive text",
                into: target,
                allowPasteboardFallback: false,
                requiresFrontmostTarget: true
            )
        ) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testCapturedTargetRechecksExactControlAtGlobalPasteBoundary() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            focusedElementChangesBeforeGlobalPaste: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("wrong field", into: target)) { error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExactPasteRefusesSecureFocusSwitchDuringRangeRead() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedRangeMutationDuringExactPasteEvidenceRead:
                .focusToSecureField,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("credential", into: target)) {
            error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExactPasteRefusesNonsecureFocusSwitchDuringRangeRead() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedRangeMutationDuringExactPasteEvidenceRead:
                .focusToNonsecureField,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("wrong field", into: target)) {
            error in
            XCTAssertEqual(error as? InsertionError, .targetFieldChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testExactPasteReceiptTreatsSecureFocusSwitchAsSensitiveUnknown() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedRangeMutationDuringExactPasteReceiptRead:
                .focusToSecureField,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("credential", into: target)) {
            error in
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveInsertionUnverified
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard
                    == true
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.exactPasteReceiptRangeMutationCount, 1)
    }

    func testExactPasteReceiptTreatsUnknownSecurityAsSensitiveUnknown() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedRangeMutationDuringExactPasteReceiptRead: .securityUnknown,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("credential", into: target)) {
            error in
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveInsertionUnverified
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard
                    == true
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.exactPasteReceiptRangeMutationCount, 1)
    }

    func testExactPasteWithoutBaselineNeverInventsReceiptConfirmation() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedTextRange: nil,
            selectedRangeMutationDuringExactPasteReceiptRead:
                .focusToSecureField,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("private text", into: target)) {
            XCTAssertEqual($0 as? InsertionError, .insertionUnverified)
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 1)
        XCTAssertEqual(environment.exactPasteReceiptRangeMutationCount, 0)
    }

    func testExactPasteWithoutBaselineMapsPostEventUnknownSecurityAsSensitive() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            selectedTextRange: nil,
            securityUnknownBeforeExactPasteUnavailableReceipt: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertThrowsError(try inserter.insert("credential", into: target)) {
            XCTAssertEqual(
                $0 as? InsertionError,
                .sensitiveInsertionUnverified
            )
            XCTAssertTrue(
                ($0 as? InsertionError)?.requiresSensitiveContentDiscard
                    == true
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 1)
        XCTAssertEqual(environment.selectedTextRangeReadCount, 1)
        XCTAssertEqual(environment.exactPasteReceiptRangeMutationCount, 0)
    }

    func testSecureFieldRequiresDiscardWhileOtherFailuresRemainRecoverable() {
        XCTAssertTrue(InsertionError.secureField.requiresSensitiveContentDiscard)
        XCTAssertTrue(
            InsertionError.targetSecurityUnverifiable
                .requiresSensitiveContentDiscard
        )
        XCTAssertTrue(
            InsertionError.sensitiveInsertionUnverified
                .requiresSensitiveContentDiscard
        )
        XCTAssertFalse(InsertionError.noTargetApplication.requiresSensitiveContentDiscard)
        XCTAssertFalse(InsertionError.accessibilityNotTrusted.requiresSensitiveContentDiscard)
        XCTAssertFalse(InsertionError.focusChanged.requiresSensitiveContentDiscard)
        XCTAssertFalse(InsertionError.insertionRejected.requiresSensitiveContentDiscard)
        XCTAssertFalse(InsertionError.insertionUnverified.requiresSensitiveContentDiscard)
    }

    func testClipboardOwnershipFailuresPreserveNewerCopyWithTruthfulRecovery() {
        let beforeEvent = InsertionError.clipboardChangedBeforeInsertion
        let afterEvent = InsertionError.clipboardChangedAfterInsertionBegan

        XCTAssertTrue(beforeEvent.requiresExternalClipboardPreservation)
        XCTAssertTrue(afterEvent.requiresExternalClipboardPreservation)
        XCTAssertFalse(beforeEvent.requiresSensitiveContentDiscard)
        XCTAssertFalse(afterEvent.requiresSensitiveContentDiscard)
        XCTAssertTrue(
            beforeEvent.clipboardPreservationUserMessage?
                .contains("no paste command was sent") == true
        )
        XCTAssertTrue(
            afterEvent.clipboardPreservationUserMessage?
                .contains("paste command was sent") == true
        )
        XCTAssertTrue(
            afterEvent.clipboardPreservationUserMessage?
                .contains("newer clipboard was preserved") == true
        )
        XCTAssertTrue(
            InsertionError.accessibilityInsertionUnverifiedPreservingClipboard
                .requiresExternalClipboardPreservation
        )
        XCTAssertTrue(
            InsertionError.accessibilityInsertionUnverifiedPreservingClipboard
                .clipboardPreservationUserMessage?
                .contains("direct insertion") == true
        )
        XCTAssertTrue(
            InsertionError.clipboardRestorationUnverified
                .requiresExternalClipboardPreservation
        )
        XCTAssertFalse(
            InsertionError.clipboardRestorationUnverified
                .requiresSensitiveContentDiscard
        )
        XCTAssertTrue(
            InsertionError.clipboardRestorationUnverified
                .clipboardPreservationUserMessage?
                .contains("could not verify restoration") == true
        )
        let postEventRestoration = InsertionError
            .insertionAndClipboardRestorationUnverified
        XCTAssertTrue(postEventRestoration.requiresExternalClipboardPreservation)
        XCTAssertFalse(postEventRestoration.requiresSensitiveContentDiscard)
        XCTAssertTrue(
            postEventRestoration.clipboardPreservationUserMessage?
                .contains("paste command was sent") == true
        )
        XCTAssertTrue(
            postEventRestoration.clipboardPreservationUserMessage?
                .contains("No second paste was sent") == true
        )
        for error in [
            InsertionError.sensitiveClipboardRestorationUnverifiedBeforeInsertion,
            InsertionError.sensitiveClipboardRestorationUnverifiedAfterInsertionBegan,
        ] {
            XCTAssertTrue(error.requiresSensitiveContentDiscard)
            XCTAssertTrue(error.requiresExternalClipboardPreservation)
            XCTAssertTrue(
                error.clipboardPreservationUserMessage?
                    .contains("clipboard") == true
            )
            XCTAssertTrue(
                error.clipboardPreservationUserMessage?
                    .contains("Nothing was saved") == true
            )
        }
    }

    func testOnlyDeliveryOrRollbackUnknownsRequireCancellationSafetyNotice() {
        let safetyNoticeOutcomes: [InsertionError] = [
            .clipboardRestorationUnverified,
            .sensitiveClipboardRestorationUnverifiedBeforeInsertion,
            .insertionUnverified,
            .accessibilityInsertionUnverifiedPreservingClipboard,
            .clipboardChangedAfterInsertionBegan,
            .insertionAndClipboardRestorationUnverified,
            .sensitiveInsertionUnverified,
            .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan,
        ]
        for error in safetyNoticeOutcomes {
            XCTAssertTrue(
                error.requiresCancellationSafetyNotice,
                "\(error) must preserve its cancellation inspection warning"
            )
            XCTAssertTrue(
                error.requiresReinsertInspection,
                "\(error) must block re-insertion until explicit acknowledgement"
            )
        }

        let preEventOutcomes: [InsertionError] = [
            .secureField,
            .targetSecurityUnverifiable,
            .focusChanged,
            .targetFieldChanged,
            .insertionRejected,
            .clipboardChangedBeforeInsertion,
        ]
        for error in preEventOutcomes {
            XCTAssertFalse(
                error.requiresCancellationSafetyNotice,
                "\(error) must remain silent after cancellation"
            )
            XCTAssertFalse(
                error.requiresReinsertInspection,
                "\(error) must remain directly retryable"
            )
        }
    }

    func testConfirmedAXInsertionAllowsAutoCopyOnlyAtUnchangedGeneration() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            axInsertionVerification: .confirmed,
            pasteboardChangeCount: 7,
            pasteboardChangeCountAfterAXAttempt: nil
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(
            result.method,
            InsertionResult.Method.accessibilitySelectedText
        )
        XCTAssertEqual(
            result.clipboardDisposition,
            InsertionResult.ClipboardDisposition.copyIfUnchanged(
                expectedChangeCount: 7
            )
        )
    }

    func testConfirmedAXInsertionPreservesClipboardChangedDuringVerification() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            axInsertionVerification: .confirmed,
            pasteboardChangeCount: 7,
            pasteboardChangeCountAfterAXAttempt: 8
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(
            result.method,
            InsertionResult.Method.accessibilitySelectedText
        )
        XCTAssertEqual(
            result.clipboardDisposition,
            InsertionResult.ClipboardDisposition.newerExternalContentPreserved
        )
    }

    func testConfirmedSyncPasteRestorationWarningRemainsSuccessful() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            pasteVerification: .confirmedWithClipboardRestorationUnverified
        )
        let inserter = TextInserter(environment: environment)

        let result = try inserter.insert("hello", into: 42)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(
            result.clipboardDisposition,
            .pasteTransportRestorationUnverified
        )
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    @MainActor
    func testConfirmedDynamicPasteRestorationWarningRemainsSuccessful() async throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pasteVerification: .confirmedWithClipboardRestorationUnverified
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex"
        )!
        let target = try await inserter.prepareTargetForOrdinaryCapture(lock)

        let result = try await inserter.insertOrdinary("hello", into: target)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(
            result.clipboardDisposition,
            .pasteTransportRestorationUnverified
        )
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testUnverifiedAXInsertionPreservesClipboardChangedDuringVerification() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            axInsertionVerification: .outcomeUnknown,
            pasteboardChangeCount: 7,
            pasteboardChangeCountAfterAXAttempt: 8
        )
        let inserter = TextInserter(environment: environment)

        XCTAssertThrowsError(try inserter.insert("hello", into: 42)) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .accessibilityInsertionUnverifiedPreservingClipboard
            )
        }
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRechecksSecureFieldAtAXWriteBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureFieldBeforeAXWrite: true,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockAllowsAXInsertionWhileOwnOverlayIsFrontmost() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 999,
            ownPID: 999,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        let result = try inserter.insert("hello", into: lock)

        XCTAssertEqual(result.method, .accessibilitySelectedText)
        XCTAssertEqual(environment.axInsertionAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRejectsBackgroundAXAfterInterveningAppActivation() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 999,
            ownPID: 999,
            currentActivationGeneration: 8,
            axInsertionSucceeds: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            activationGeneration: 7
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockNeverUsesGlobalPasteWhileOwnOverlayIsFrontmost() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            frontmostPID: 999,
            ownPID: 999,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockUsesConfirmedPasteWhenLockedTargetRemainsFrontmost() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        let result = try inserter.insert("hello", into: lock)

        XCTAssertEqual(result.method, .pasteboard)
        XCTAssertEqual(environment.pasteAttempts, 1)
    }

    func testFocusLockRechecksFocusBeforeFallingBackToGlobalPaste() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPIDAfterAXAttempt: 84,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.axInsertionAttempts, 0)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRevalidatesFocusAtGlobalPasteEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            frontmostPIDBeforeGlobalPaste: 84,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRevalidatesIdentityAtGlobalPasteEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            bundleIDBeforeGlobalPaste: "com.example.Replacement",
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRevalidatesFocusedControlAtGlobalPasteEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            focusedElementChangesBeforeGlobalPaste: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRechecksSecureFieldAtGlobalPasteEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            secureFieldBeforeGlobalPaste: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.pastePreparationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testFocusLockRechecksSecureFieldImmediatelyBeforePasteboardStaging() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            secureFieldBeforePasteboardStaging: true,
            pasteVerification: .confirmed
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "Visual Studio Code"
        )!

        XCTAssertThrowsError(try inserter.insert("private text", into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.preStagingValidationAttempts, 1)
        XCTAssertEqual(environment.pasteAttempts, 0)
    }

    func testTargetSnapshotFreezesProfileWithItsLockedTargetForRetry() {
        let tracker = FrontmostTracker()
        tracker.noteActivation(
            pid: 42,
            bundleID: "com.apple.mail",
            appName: "Mail",
            isSelf: false
        )

        let captured = tracker.targetSnapshot(profileOverrideID: nil)
        XCTAssertEqual(captured.focusLock?.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(captured.profile.id, "email")
        XCTAssertEqual(captured.focusLock?.activationGeneration, 1)

        // Duplicate activation of the same target is not a different app.
        tracker.noteActivation(
            pid: 42,
            bundleID: "com.apple.mail",
            appName: "Mail",
            isSelf: false
        )
        XCTAssertEqual(tracker.currentActivationGeneration(), 1)

        // Our overlay taking focus is not an intervening target activation.
        tracker.noteActivation(
            pid: 999,
            bundleID: "com.lockedinflow.mac",
            appName: "LockedIn Flow",
            isSelf: true
        )
        XCTAssertEqual(tracker.currentActivationGeneration(), 1)

        // A later application switch changes the next snapshot, while the
        // already-captured retry context remains internally consistent.
        tracker.noteActivation(
            pid: 84,
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            isSelf: false
        )
        let next = tracker.targetSnapshot(profileOverrideID: nil)
        XCTAssertEqual(next.profile.id, "coding")
        XCTAssertEqual(next.focusLock?.activationGeneration, 2)
        XCTAssertEqual(captured.profile.id, "email")
        XCTAssertEqual(captured.focusLock?.processIdentifier, 42)
        XCTAssertEqual(captured.focusLock?.activationGeneration, 1)
    }

    func testTargetSnapshotAppliesExplicitProfileOverrideToLockedTarget() {
        let tracker = FrontmostTracker()
        tracker.noteActivation(
            pid: 42,
            bundleID: "com.apple.mail",
            appName: "Mail",
            isSelf: false
        )

        let captured = tracker.targetSnapshot(profileOverrideID: "coding")

        XCTAssertEqual(captured.focusLock?.bundleIdentifier, "com.apple.mail")
        XCTAssertEqual(captured.profile.id, "coding")
    }

    func testFocusLockRequiresPIDBundleAndPreservesOptionalNameContract() {
        XCTAssertNil(
            InsertionFocusLock(
                processIdentifier: 0,
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit"
            ))
        XCTAssertNil(
            InsertionFocusLock(
                processIdentifier: 42,
                bundleIdentifier: "  ",
                appName: "TextEdit"
            ))

        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: nil
        )!
        XCTAssertTrue(
            lock.matches(
                processIdentifier: 42,
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit"
            ))
        XCTAssertFalse(
            lock.matches(
                processIdentifier: 43,
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit"
            ))
    }

    func testFocusLockedUndoRejectsDriftWithoutSendingGlobalEvent() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPID: 84
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.postUndoKeystroke(into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.undoAttempts, 0)
    }

    func testFocusLockedUndoRejectsSecureFieldWithoutSendingGlobalEvent() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            secureField: true
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.postUndoKeystroke(into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }
        XCTAssertEqual(environment.undoAttempts, 0)
    }

    func testFocusLockedUndoSendsEventOnlyToStableFrontmostTarget() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        try inserter.postUndoKeystroke(into: lock)

        XCTAssertEqual(environment.undoAttempts, 1)
    }

    func testFocusLockedUndoRevalidatesFocusAtGlobalEventBoundary() {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            frontmostPIDBeforeUndo: 84
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!

        XCTAssertThrowsError(try inserter.postUndoKeystroke(into: lock)) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }
        XCTAssertEqual(environment.undoPreparationAttempts, 1)
        XCTAssertEqual(environment.undoAttempts, 0)
    }

    func testPasteVerificationRequiresExpectedUTF16CaretAdvance() {
        XCTAssertEqual(
            PasteVerification.evaluate(
                before: CFRange(location: 7, length: 3),
                after: CFRange(location: 12, length: 0),
                insertedUTF16Count: 5
            ),
            .confirmed
        )
        XCTAssertEqual(
            PasteVerification.evaluate(
                before: CFRange(location: 7, length: 3),
                after: CFRange(location: 7, length: 3),
                insertedUTF16Count: 5
            ),
            .rejected
        )
        XCTAssertEqual(
            PasteVerification.evaluate(
                before: nil,
                after: CFRange(location: 12, length: 0),
                insertedUTF16Count: 5
            ),
            .unavailable
        )
    }

    func testPasteVerificationWaitsThroughTransientMissingRefreshedControl() {
        var accumulator = PasteVerificationAccumulator()
        let before = CFRange(location: 0, length: 0)

        XCTAssertFalse(
            accumulator.observe(
                before: before,
                after: nil,
                insertedUTF16Count: 22
            ))
        XCTAssertEqual(accumulator.result, .unavailable)
        XCTAssertTrue(
            accumulator.observe(
                before: before,
                after: CFRange(location: 22, length: 0),
                insertedUTF16Count: 22
            ))
        XCTAssertEqual(accumulator.result, .confirmed)
    }

    func testPasteVerificationNeverConfirmsPersistentMissingRefreshedControl() {
        var accumulator = PasteVerificationAccumulator()
        let before = CFRange(location: 0, length: 0)

        for _ in 0..<16 {
            XCTAssertFalse(
                accumulator.observe(
                    before: before,
                    after: nil,
                    insertedUTF16Count: 22
                ))
        }
        XCTAssertEqual(accumulator.result, .unavailable)
    }

    func testStagedPasteRestoresExactItemBoundariesAndRepresentations() throws {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

        let result = try withStagedPasteboardString(
            "temporary dictation",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {}
        ) { validateStagedOwnership in
            try validateStagedOwnership()
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "temporary dictation")
            return .confirmed
        }

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    func testSyncValueFailuresRestoreClipboardWhenAutoCopyIsEnabled() throws {
        for failedVerification in [
            PasteVerification.unavailable,
            PasteVerification.rejected,
        ] {
            let pasteboard = makeMultiItemPasteboard()
            let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

            let result = try withStagedPasteboardString(
                "temporary dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                return failedVerification
            }

            XCTAssertEqual(result, failedVerification)
            XCTAssertEqual(
                PasteboardContentsSnapshot(pasteboard: pasteboard),
                original
            )
            assertMultiItemPasteboardWasRestored(pasteboard)
        }
    }

    func testSyncValueFailureReportsPostEventRestorationFailureWithAutoCopy() {
        let pasteboard = makeMultiItemPasteboard()

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "temporary dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                return PasteVerification.unavailable
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .insertionAndClipboardRestorationUnverified
            )
        }
    }

    func testAutomaticClipboardWriterPreservesNewerExplicitCopy() {
        let pasteboard = makeMultiItemPasteboard()
        let baseline = PasteboardGenerationBaseline(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("newer explicit copy", forType: .string)

        XCTAssertEqual(
            baseline.writeStringIfUnchanged("automatic transcript", to: pasteboard),
            .newerContentPreserved
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "newer explicit copy"
        )
    }

    func testGenerationBaselineDoesNotReadExistingClipboardRepresentations() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("lockedin-lazy-baseline-\(UUID().uuidString)")
        )
        let provider = CountingPasteboardDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        provider.reset()

        _ = PasteboardGenerationBaseline(pasteboard: pasteboard)

        XCTAssertEqual(provider.requestCount, 0)
    }

    func testAutomaticClipboardWriterWritesWhenBaselineIsUnchanged() {
        let pasteboard = makeMultiItemPasteboard()
        let baseline = PasteboardGenerationBaseline(pasteboard: pasteboard)

        XCTAssertEqual(
            baseline.writeStringIfUnchanged("automatic transcript", to: pasteboard),
            .written
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "automatic transcript"
        )
    }

    func testAutomaticClipboardWriterFailureRestoresExactBaseline() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "automatic transcript",
                to: pasteboard,
                ifChangeCountMatches: expected,
                writeStagedItem: { _, _ in false }
            ),
            .originalContentsRestored
        )
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
    }

    func testRecoveryClipboardWriterRefusesAdvancedRestoredGeneration() {
        let pasteboard = makeMultiItemPasteboard()
        let baseline = PasteboardGenerationBaseline(pasteboard: pasteboard)
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary stage", forType: .string)
        original.restore(to: pasteboard)

        XCTAssertEqual(
            baseline.writeStringIfUnchanged(
                "recovery transcript",
                to: pasteboard
            ),
            .newerContentPreserved
        )
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
    }

    func testRecoveryClipboardWriterTreatsIdenticalExplicitCopyAsNewer() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("lockedin-identical-copy-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("same contents", forType: .string)
        let baseline = PasteboardGenerationBaseline(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("same contents", forType: .string)

        XCTAssertEqual(
            baseline.writeStringIfUnchanged("recovery transcript", to: pasteboard),
            .newerContentPreserved
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "same contents")
    }

    func testAXAutoCopyWriterRequiresExactPostVerificationGeneration() {
        let pasteboard = makeMultiItemPasteboard()
        let expected = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("newer explicit copy", forType: .string)

        XCTAssertEqual(
            writePasteboardString(
                "automatic transcript",
                to: pasteboard,
                ifChangeCountMatches: expected
            ),
            .newerContentPreserved
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "newer explicit copy"
        )
    }

    func testAXAutoCopyWriterWritesAtExactPostVerificationGeneration() {
        let pasteboard = makeMultiItemPasteboard()
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "automatic transcript",
                to: pasteboard,
                ifChangeCountMatches: expected
            ),
            .written
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "automatic transcript"
        )
    }

    func testAXAutoCopyWriterFailureRestoresExactPriorClipboard() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "automatic transcript",
                to: pasteboard,
                ifChangeCountMatches: expected,
                writeStagedItem: { _, _ in false }
            ),
            .originalContentsRestored
        )
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
    }

    func testAXAutoCopyWriterReportsUnverifiedWhenRollbackFails() {
        let pasteboard = makeMultiItemPasteboard()
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "automatic transcript",
                to: pasteboard,
                ifChangeCountMatches: expected,
                writeStagedItem: { _, _ in false },
                restoreSnapshot: { _, _ in false }
            ),
            .outcomeUnverified
        )
    }

    func testAXAutoCopyWriterReportsUnverifiedForPostClearRace() {
        let pasteboard = makeMultiItemPasteboard()
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "alpha",
                to: pasteboard,
                ifChangeCountMatches: expected,
                writeStagedItem: { pasteboard, item in
                    let wrote = pasteboard.writeObjects([item])
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    return wrote
                }
            ),
            .outcomeUnverified
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    func testAXAutoCopyWriterDoesNotClaimPreservationAfterFailedRacingWrite() {
        let pasteboard = makeMultiItemPasteboard()
        let expected = pasteboard.changeCount

        XCTAssertEqual(
            writePasteboardString(
                "alpha",
                to: pasteboard,
                ifChangeCountMatches: expected,
                writeStagedItem: { pasteboard, _ in
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    return false
                }
            ),
            .outcomeUnverified
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    func testPasteboardClearClaimsGenerationAndOneWriteFillsIt() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("lockedin-generation-\(UUID().uuidString)")
        )
        let before = pasteboard.changeCount
        let cleared = pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("alpha", forType: .string))

        XCTAssertEqual(cleared, before + 1)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        // This is the macOS ownership-generation contract used by staging;
        // readback is still required because it is not a cross-process CAS.
        XCTAssertEqual(pasteboard.changeCount, cleared)
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
    }

    func testLateBoundaryFailureRestoresExactItemBoundariesAndRepresentations() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "temporary private dictation",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                // This is the same failure timing as focus/identity validation
                // immediately before the global Cmd+V event is posted.
                try validateStagedOwnership()
                XCTAssertEqual(pasteboard.string(forType: .string), "temporary private dictation")
                throw InsertionError.focusChanged
            }
        ) { error in
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }

        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    func testPreStagingSecureFailureNeverWritesSensitiveTextWithAutoCopyEnabled() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        var operationRan = false

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "credential that must never be staged",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {
                    XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
                    XCTAssertNil(
                        pasteboard.pasteboardItems?.first(where: {
                            $0.string(forType: .string) == "credential that must never be staged"
                        })
                    )
                    throw InsertionError.secureField
                }
            ) { _ in
                operationRan = true
                return .confirmed
            }
        ) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }

        XCTAssertFalse(operationRan)
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    func testLateSecureFailureRestoresClipboardEvenWithAutoCopyEnabled() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "temporary private dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                XCTAssertEqual(pasteboard.string(forType: .string), "temporary private dictation")
                throw InsertionError.secureField
            }
        ) { error in
            XCTAssertEqual(error as? InsertionError, .secureField)
        }

        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    func testSyncStagingUsesClipboardWrittenDuringValidationAsRestoreBaseline() throws {
        let pasteboard = makeMultiItemPasteboard()
        let newerClipboard = "copy made during target validation"

        _ = try withStagedPasteboardString(
            "temporary dictation",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {
                pasteboard.clearContents()
                pasteboard.setString(newerClipboard, forType: .string)
            }
        ) { validateStagedOwnership in
            try validateStagedOwnership()
            return .confirmed
        }

        XCTAssertEqual(pasteboard.string(forType: .string), newerClipboard)
    }

    func testSyncStagingReportsUnverifiedEqualLengthWriterRace() {
        let pasteboard = makeMultiItemPasteboard()
        var operationRan = false

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                writeStagedItem: { pasteboard, item in
                    let wrote = pasteboard.writeObjects([item])
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    return wrote
                }
            ) { _ in
                operationRan = true
                return .confirmed
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardRestorationUnverified
            )
        }

        XCTAssertFalse(operationRan)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    func testSyncStagingWriteFailureRestoresExactOriginal() {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        var operationRan = false

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                writeStagedItem: { _, _ in false }
            ) { _ in
                operationRan = true
                return .confirmed
            }
        ) { error in
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }

        XCTAssertFalse(operationRan)
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
    }

    func testSyncStagingReportsUnverifiedWhenInitialRollbackFails() {
        let pasteboard = makeMultiItemPasteboard()
        var operationRan = false

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                writeStagedItem: { _, _ in false },
                restoreSavedSnapshot: { _, _ in false }
            ) { _ in
                operationRan = true
                return .confirmed
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardRestorationUnverified
            )
        }

        XCTAssertFalse(operationRan)
    }

    func testSyncPreEventSensitiveFailureReportsUnverifiedRollback() {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "sensitive transcript",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { validateStagedOwnership in
                try performSynchronousPasteEventTransport(
                    validateStagedOwnership: validateStagedOwnership,
                    postEvent: { _ in
                        throw InsertionError.secureField
                    },
                    receipt: { _ in
                        eventCount += 1
                        return PasteVerification.confirmed
                    }
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveClipboardRestorationUnverifiedBeforeInsertion
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(eventCount, 0)
    }

    @MainActor
    func testCancelledSyncPreEventRollbackFailureKeepsClipboardWarning() async {
        let cases: [(original: InsertionError, expected: InsertionError)] = [
            (.focusChanged, .clipboardRestorationUnverified),
            (
                .secureField,
                .sensitiveClipboardRestorationUnverifiedBeforeInsertion
            ),
        ]

        for testCase in cases {
            let pasteboard = makeMultiItemPasteboard()
            var observedError: InsertionError?
            var observedCancellation = false
            var eventCount = 0
            let task = Task { @MainActor in
                do {
                    let _: PasteVerification = try withStagedPasteboardString(
                        "staged test transcript",
                        on: pasteboard,
                        restoreClipboard: false,
                        validateBeforeStaging: {},
                        restoreSavedSnapshot: { _, _ in false }
                    ) { validateStagedOwnership in
                        try performSynchronousPasteEventTransport(
                            validateStagedOwnership: validateStagedOwnership,
                            postEvent: { validateOwnershipAtEvent in
                                try validateOwnershipAtEvent()
                                withUnsafeCurrentTask { $0?.cancel() }
                                throw testCase.original
                            },
                            receipt: { _ in
                                eventCount += 1
                                return .confirmed
                            }
                        )
                    }
                    XCTFail("cancelled pre-event failure must terminate")
                } catch {
                    observedError = error as? InsertionError
                    observedCancellation = Task.isCancelled
                }
            }
            await task.value

            XCTAssertTrue(observedCancellation)
            XCTAssertEqual(observedError, testCase.expected)
            XCTAssertTrue(
                observedError?.requiresCancellationSafetyNotice == true
            )
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(
                pasteboard.string(forType: .string),
                "staged test transcript"
            )
        }
    }

    func testSyncPostEventSensitiveFailureReportsUnverifiedRollback() {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "sensitive transcript",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { validateStagedOwnership in
                try performSynchronousPasteEventTransport(
                    validateStagedOwnership: validateStagedOwnership,
                    postEvent: { validateOwnershipAtEvent in
                        try validateOwnershipAtEvent()
                        eventCount += 1
                    },
                    receipt: { _ in
                        throw InsertionError.secureField
                    }
                ) as PasteVerification
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(eventCount, 1)
    }

    func testSyncConfirmedPasteRemainsSuccessfulWhenRestorationFails() throws {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        let verification = try withStagedPasteboardString(
            "confirmed transcript",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {},
            restoreSavedSnapshot: { _, _ in false }
        ) { validateStagedOwnership in
            try performSynchronousPasteEventTransport(
                validateStagedOwnership: validateStagedOwnership,
                postEvent: { validateOwnershipAtEvent in
                    try validateOwnershipAtEvent()
                    eventCount += 1
                },
                receipt: { validateOwnershipDuringReceipt in
                    try validateOwnershipDuringReceipt()
                    return .confirmed
                }
            )
        }

        XCTAssertEqual(
            verification,
            .confirmedWithClipboardRestorationUnverified
        )
        XCTAssertEqual(eventCount, 1)
    }

    func testSyncPostEventUnknownRetainsPhaseWhenRestorationFails() {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "unverified transcript",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { validateStagedOwnership in
                try performSynchronousPasteEventTransport(
                    validateStagedOwnership: validateStagedOwnership,
                    postEvent: { validateOwnershipAtEvent in
                        try validateOwnershipAtEvent()
                        eventCount += 1
                    },
                    receipt: { _ in
                        throw InsertionError.focusChanged
                    }
                ) as PasteVerification
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .insertionAndClipboardRestorationUnverified
            )
        }
        XCTAssertEqual(eventCount, 1)
    }

    func testSynchronousPasteTransportRejectsSameLengthReplacementBeforeEvent() {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try performSynchronousPasteEventTransport(
                    validateStagedOwnership: validateStagedOwnership,
                    postEvent: { validateOwnershipAtEvent in
                        // Same UTF-16 length as the transcript: a caret-only
                        // receipt could otherwise falsely confirm this value.
                        pasteboard.clearContents()
                        pasteboard.setString("bravo", forType: .string)
                        try validateOwnershipAtEvent()
                        eventCount += 1
                    },
                    receipt: { _ in PasteVerification.confirmed }
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardChangedBeforeInsertion
            )
        }

        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    func testSynchronousPasteTransportTreatsPostEventOwnershipLossAsUnknown() {
        let pasteboard = makeMultiItemPasteboard()
        var eventCount = 0

        XCTAssertThrowsError(
            try withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try performSynchronousPasteEventTransport(
                    validateStagedOwnership: validateStagedOwnership,
                    postEvent: { validateOwnershipAtEvent in
                        try validateOwnershipAtEvent()
                        eventCount += 1
                    },
                    receipt: { validateOwnershipDuringReceipt in
                        try validateOwnershipDuringReceipt()
                        pasteboard.clearContents()
                        pasteboard.setString("bravo", forType: .string)
                        try validateOwnershipDuringReceipt()
                        return PasteVerification.confirmed
                    }
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardChangedAfterInsertionBegan
            )
        }

        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    func testSyncPreEventOwnershipLossPrecedesFocusErrorButNotSecureEvidence() {
        for (underlying, expected) in [
            (InsertionError.focusChanged, InsertionError.clipboardChangedBeforeInsertion),
            (InsertionError.secureField, InsertionError.secureField),
        ] {
            let pasteboard = makeMultiItemPasteboard()
            var eventCount = 0
            XCTAssertThrowsError(
                try withStagedPasteboardString(
                    "alpha",
                    on: pasteboard,
                    restoreClipboard: true,
                    validateBeforeStaging: {}
                ) { validateStagedOwnership in
                    try performSynchronousPasteEventTransport(
                        validateStagedOwnership: validateStagedOwnership,
                        postEvent: { _ in
                            pasteboard.clearContents()
                            pasteboard.setString("bravo", forType: .string)
                            throw underlying
                        },
                        receipt: { _ in
                            eventCount += 1
                            return PasteVerification.confirmed
                        }
                    )
                }
            ) { error in
                XCTAssertEqual(error as? InsertionError, expected)
            }
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
        }
    }

    func testSyncPostEventOwnershipLossPrecedesPolicyErrorButNotSecureEvidence() {
        for (underlying, expected) in [
            (InsertionError.focusChanged, InsertionError.clipboardChangedAfterInsertionBegan),
            (InsertionError.secureField, InsertionError.sensitiveInsertionUnverified),
        ] {
            let pasteboard = makeMultiItemPasteboard()
            var eventCount = 0
            XCTAssertThrowsError(
                try withStagedPasteboardString(
                    "alpha",
                    on: pasteboard,
                    restoreClipboard: true,
                    validateBeforeStaging: {}
                ) { validateStagedOwnership in
                    try performSynchronousPasteEventTransport(
                        validateStagedOwnership: validateStagedOwnership,
                        postEvent: { validate in
                            try validate()
                            eventCount += 1
                        },
                        receipt: { _ in
                            pasteboard.clearContents()
                            pasteboard.setString("bravo", forType: .string)
                            throw underlying
                        }
                    ) as PasteVerification
                }
            ) { error in
                XCTAssertEqual(error as? InsertionError, expected)
            }
            XCTAssertEqual(eventCount, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
        }
    }

    @MainActor
    func testAsyncStagedPasteRestoresExactOriginalWhenStillOwner() async throws {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

        let result = try await withStagedPasteboardString(
            "temporary async dictation",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {}
        ) { validateStagedOwnership in
            try validateStagedOwnership()
            XCTAssertEqual(
                pasteboard.string(forType: .string),
                "temporary async dictation"
            )
            await Task.yield()
            return .confirmed
        }

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    @MainActor
    func testAsyncStagedPastePreservesNewerExternalClipboardWrite() async throws {
        let pasteboard = makeMultiItemPasteboard()

        _ = try await withStagedPasteboardString(
            "temporary async dictation",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {}
        ) { _ in
            pasteboard.clearContents()
            pasteboard.setString("new external copy", forType: .string)
            await Task.yield()
            return .confirmed
        }

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "new external copy"
        )
    }

    @MainActor
    func testAsyncValueFailuresRestoreClipboardWhenAutoCopyIsEnabled() async throws {
        for failedVerification in [
            PasteVerification.unavailable,
            PasteVerification.rejected,
        ] {
            let pasteboard = makeMultiItemPasteboard()
            let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

            let result = try await withStagedPasteboardString(
                "temporary async dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                await Task.yield()
                return failedVerification
            }

            XCTAssertEqual(result, failedVerification)
            XCTAssertEqual(
                PasteboardContentsSnapshot(pasteboard: pasteboard),
                original
            )
            assertMultiItemPasteboardWasRestored(pasteboard)
        }
    }

    @MainActor
    func testAsyncValueFailureReportsPostEventRestorationFailureWithAutoCopy() async {
        let pasteboard = makeMultiItemPasteboard()

        do {
            let _: PasteVerification = try await withStagedPasteboardString(
                "temporary async dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                await Task.yield()
                return .rejected
            }
            XCTFail("failed receipt must not retain a staged transcript")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .insertionAndClipboardRestorationUnverified
            )
        }
    }

    @MainActor
    func testAsyncStagingUsesClipboardWrittenDuringValidationAsRestoreBaseline() async throws {
        let pasteboard = makeMultiItemPasteboard()
        let newerClipboard = "copy made during async target validation"

        _ = try await withStagedPasteboardString(
            "temporary async dictation",
            on: pasteboard,
            restoreClipboard: true,
            validateBeforeStaging: {
                pasteboard.clearContents()
                pasteboard.setString(newerClipboard, forType: .string)
            }
        ) { validateStagedOwnership in
            try validateStagedOwnership()
            await Task.yield()
            return .confirmed
        }

        XCTAssertEqual(pasteboard.string(forType: .string), newerClipboard)
    }

    @MainActor
    func testAsyncStagingReportsUnverifiedEqualLengthWriterRace() async {
        let pasteboard = makeMultiItemPasteboard()
        var operationRan = false

        do {
            let _: PasteVerification = try await withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                writeStagedItem: { pasteboard, item in
                    let wrote = pasteboard.writeObjects([item])
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    return wrote
                }
            ) { _ in
                operationRan = true
                await Task.yield()
                return .confirmed
            }
            XCTFail("racing writer must not become the staged baseline")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardRestorationUnverified
            )
        }

        XCTAssertFalse(operationRan)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    @MainActor
    func testAsyncStagingWriteFailureRestoresExactOriginal() async {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        var operationRan = false

        do {
            let _: PasteVerification = try await withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                writeStagedItem: { _, _ in false }
            ) { _ in
                operationRan = true
                await Task.yield()
                return .confirmed
            }
            XCTFail("failed staged write must terminate before operation")
        } catch {
            XCTAssertEqual(error as? InsertionError, .insertionRejected)
        }

        XCTAssertFalse(operationRan)
        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
    }

    @MainActor
    func testAsyncStagingReportsUnverifiedWhenLateRollbackFails() async {
        let pasteboard = makeMultiItemPasteboard()

        do {
            let _: PasteVerification = try await withStagedPasteboardString(
                "alpha",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {},
                restoreSavedSnapshot: { _, _ in false }
            ) { _ in
                await Task.yield()
                throw InsertionError.focusChanged
            }
            XCTFail("unverified rollback must terminate")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardRestorationUnverified
            )
        }
    }

    @MainActor
    func testDynamicPreEventSensitiveFailureReportsUnverifiedRollback() async {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        var eventCount = 0

        do {
            _ = try await performDynamicPasteTransport(
                text: "sensitive transcript",
                validateBeforeStaging: {},
                resolveTargetAtGlobalEvent: { evidence },
                stage: { validation, operation in
                    try await withStagedPasteboardString(
                        "sensitive transcript",
                        on: pasteboard,
                        restoreClipboard: true,
                        validateBeforeStaging: validation,
                        restoreSavedSnapshot: { _, _ in false },
                        operation: operation
                    )
                },
                postEvent: { _, _ in
                    throw InsertionError.secureField
                },
                resolveVerificationTargetAfterPaste: {
                    eventCount += 1
                    return evidence
                },
                receiptDelay: { await Task.yield() },
                acquiresPasteboardLease: false
            )
            XCTFail("sensitive pre-event failure must terminate")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveClipboardRestorationUnverifiedBeforeInsertion
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(eventCount, 0)
    }

    @MainActor
    func testCancelledDynamicPreEventRollbackFailureKeepsClipboardWarning() async {
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        let cases: [(original: InsertionError, expected: InsertionError)] = [
            (.focusChanged, .clipboardRestorationUnverified),
            (
                .secureField,
                .sensitiveClipboardRestorationUnverifiedBeforeInsertion
            ),
        ]

        for testCase in cases {
            let pasteboard = makeMultiItemPasteboard()
            var observedError: InsertionError?
            var observedCancellation = false
            var eventCount = 0
            let task = Task { @MainActor in
                do {
                    _ = try await performDynamicPasteTransport(
                        text: "staged test transcript",
                        validateBeforeStaging: {},
                        resolveTargetAtGlobalEvent: { evidence },
                        stage: { validation, operation in
                            try await withStagedPasteboardString(
                                "staged test transcript",
                                on: pasteboard,
                                restoreClipboard: false,
                                validateBeforeStaging: validation,
                                restoreSavedSnapshot: { _, _ in false },
                                operation: operation
                            )
                        },
                        postEvent: { _, validateOwnershipAtEvent in
                            try validateOwnershipAtEvent()
                            withUnsafeCurrentTask { $0?.cancel() }
                            throw testCase.original
                        },
                        resolveVerificationTargetAfterPaste: {
                            eventCount += 1
                            return evidence
                        },
                        receiptDelay: { await Task.yield() },
                        acquiresPasteboardLease: false
                    )
                    XCTFail("cancelled pre-event failure must terminate")
                } catch {
                    observedError = error as? InsertionError
                    observedCancellation = Task.isCancelled
                }
            }
            await task.value

            XCTAssertTrue(observedCancellation)
            XCTAssertEqual(observedError, testCase.expected)
            XCTAssertTrue(
                observedError?.requiresCancellationSafetyNotice == true
            )
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(
                pasteboard.string(forType: .string),
                "staged test transcript"
            )
        }
    }

    @MainActor
    func testDynamicPostEventSensitiveFailureReportsUnverifiedRollback() async {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        var eventCount = 0
        var receiptCount = 0

        do {
            _ = try await performDynamicPasteTransport(
                text: "sensitive transcript",
                validateBeforeStaging: {},
                resolveTargetAtGlobalEvent: { evidence },
                stage: { validation, operation in
                    try await withStagedPasteboardString(
                        "sensitive transcript",
                        on: pasteboard,
                        restoreClipboard: true,
                        validateBeforeStaging: validation,
                        restoreSavedSnapshot: { _, _ in false },
                        operation: operation
                    )
                },
                postEvent: { _, validateOwnershipAtEvent in
                    try validateOwnershipAtEvent()
                    eventCount += 1
                },
                resolveVerificationTargetAfterPaste: {
                    receiptCount += 1
                    throw InsertionError.secureField
                },
                receiptDelay: { await Task.yield() },
                acquiresPasteboardLease: false
            )
            XCTFail("sensitive post-event failure must terminate")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .sensitiveClipboardRestorationUnverifiedAfterInsertionBegan
            )
            XCTAssertTrue(
                (error as? InsertionError)?.requiresSensitiveContentDiscard == true
            )
        }
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(receiptCount, 1)
    }

    @MainActor
    func testDynamicConfirmedPasteRemainsSuccessfulWhenRestorationFails() async throws {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        let confirmedEvidence = DynamicPasteTargetEvidence(
            element: evidence.element,
            selectedTextRange: CFRange(location: 5, length: 0)
        )
        var eventCount = 0

        let verification = try await performDynamicPasteTransport(
            text: "alpha",
            validateBeforeStaging: {},
            resolveTargetAtGlobalEvent: { evidence },
            stage: { validation, operation in
                try await withStagedPasteboardString(
                    "alpha",
                    on: pasteboard,
                    restoreClipboard: true,
                    validateBeforeStaging: validation,
                    restoreSavedSnapshot: { _, _ in false },
                    operation: operation
                )
            },
            postEvent: { _, validateOwnershipAtEvent in
                try validateOwnershipAtEvent()
                eventCount += 1
            },
            resolveVerificationTargetAfterPaste: { confirmedEvidence },
            receiptDelay: { await Task.yield() },
            acquiresPasteboardLease: false
        )

        XCTAssertEqual(
            verification,
            .confirmedWithClipboardRestorationUnverified
        )
        XCTAssertEqual(eventCount, 1)
    }

    @MainActor
    func testDynamicPostEventUnknownRetainsPhaseWhenRestorationFails() async {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        var eventCount = 0

        do {
            _ = try await performDynamicPasteTransport(
                text: "alpha",
                validateBeforeStaging: {},
                resolveTargetAtGlobalEvent: { evidence },
                stage: { validation, operation in
                    try await withStagedPasteboardString(
                        "alpha",
                        on: pasteboard,
                        restoreClipboard: true,
                        validateBeforeStaging: validation,
                        restoreSavedSnapshot: { _, _ in false },
                        operation: operation
                    )
                },
                postEvent: { _, validateOwnershipAtEvent in
                    try validateOwnershipAtEvent()
                    eventCount += 1
                },
                resolveVerificationTargetAfterPaste: {
                    throw InsertionError.focusChanged
                },
                receiptDelay: { await Task.yield() },
                acquiresPasteboardLease: false
            )
            XCTFail("post-event unknown delivery must terminate")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .insertionAndClipboardRestorationUnverified
            )
        }
        XCTAssertEqual(eventCount, 1)
    }

    @MainActor
    func testDynamicPasteTransportRejectsSameLengthReplacementBeforeEvent() async {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        var eventCount = 0

        do {
            _ = try await performDynamicPasteTransport(
                text: "alpha",
                validateBeforeStaging: {},
                resolveTargetAtGlobalEvent: { evidence },
                stage: { validation, operation in
                    try await withStagedPasteboardString(
                        "alpha",
                        on: pasteboard,
                        restoreClipboard: true,
                        validateBeforeStaging: validation,
                        operation: operation
                    )
                },
                postEvent: { _, validateOwnershipAtEvent in
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    try validateOwnershipAtEvent()
                    eventCount += 1
                },
                resolveVerificationTargetAfterPaste: {
                    XCTFail("zero-event ownership loss must not enter receipt")
                    return evidence
                },
                receiptDelay: { await Task.yield() },
                acquiresPasteboardLease: false
            )
            XCTFail("same-length replacement must stop before the event")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardChangedBeforeInsertion
            )
        }

        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    @MainActor
    func testDynamicPasteTransportRejectsSameLengthReplacementDuringReceipt() async {
        let pasteboard = makeMultiItemPasteboard()
        let evidence = DynamicPasteTargetEvidence(
            element: AXUIElementCreateSystemWide(),
            selectedTextRange: CFRange(location: 0, length: 0)
        )
        var eventCount = 0
        var receiptDelayCount = 0
        var receiptResolutionCount = 0

        do {
            _ = try await performDynamicPasteTransport(
                text: "alpha",
                validateBeforeStaging: {},
                resolveTargetAtGlobalEvent: { evidence },
                stage: { validation, operation in
                    try await withStagedPasteboardString(
                        "alpha",
                        on: pasteboard,
                        restoreClipboard: true,
                        validateBeforeStaging: validation,
                        operation: operation
                    )
                },
                postEvent: { _, validateOwnershipAtEvent in
                    try validateOwnershipAtEvent()
                    eventCount += 1
                },
                resolveVerificationTargetAfterPaste: {
                    receiptResolutionCount += 1
                    // Model an external copy racing the blocking AX range read.
                    pasteboard.clearContents()
                    pasteboard.setString("bravo", forType: .string)
                    return DynamicPasteTargetEvidence(
                        element: evidence.element,
                        selectedTextRange: CFRange(location: 5, length: 0)
                    )
                },
                receiptDelay: {
                    receiptDelayCount += 1
                    await Task.yield()
                },
                acquiresPasteboardLease: false
            )
            XCTFail("post-event ownership loss must remain unknown")
        } catch {
            XCTAssertEqual(
                error as? InsertionError,
                .clipboardChangedAfterInsertionBegan
            )
        }

        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(receiptDelayCount, 1)
        XCTAssertEqual(receiptResolutionCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
    }

    @MainActor
    func testDynamicPreEventOwnershipLossPrecedesFocusErrorButNotSecureEvidence() async {
        for (underlying, expected) in [
            (InsertionError.focusChanged, InsertionError.clipboardChangedBeforeInsertion),
            (InsertionError.secureField, InsertionError.secureField),
        ] {
            let pasteboard = makeMultiItemPasteboard()
            let evidence = DynamicPasteTargetEvidence(
                element: AXUIElementCreateSystemWide(),
                selectedTextRange: CFRange(location: 0, length: 0)
            )
            var eventCount = 0
            do {
                _ = try await performDynamicPasteTransport(
                    text: "alpha",
                    validateBeforeStaging: {},
                    resolveTargetAtGlobalEvent: { evidence },
                    stage: { validation, operation in
                        try await withStagedPasteboardString(
                            "alpha",
                            on: pasteboard,
                            restoreClipboard: true,
                            validateBeforeStaging: validation,
                            operation: operation
                        )
                    },
                    postEvent: { _, _ in
                        pasteboard.clearContents()
                        pasteboard.setString("bravo", forType: .string)
                        throw underlying
                    },
                    resolveVerificationTargetAfterPaste: {
                        eventCount += 1
                        return evidence
                    },
                    receiptDelay: { await Task.yield() },
                    acquiresPasteboardLease: false
                )
                XCTFail("pre-event failure must throw")
            } catch {
                XCTAssertEqual(error as? InsertionError, expected)
            }
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
        }
    }

    @MainActor
    func testDynamicPostEventOwnershipLossPrecedesPolicyErrorButNotSecureEvidence() async {
        for (underlying, expected) in [
            (InsertionError.focusChanged, InsertionError.clipboardChangedAfterInsertionBegan),
            (InsertionError.secureField, InsertionError.sensitiveInsertionUnverified),
        ] {
            let pasteboard = makeMultiItemPasteboard()
            let evidence = DynamicPasteTargetEvidence(
                element: AXUIElementCreateSystemWide(),
                selectedTextRange: CFRange(location: 0, length: 0)
            )
            var eventCount = 0
            do {
                _ = try await performDynamicPasteTransport(
                    text: "alpha",
                    validateBeforeStaging: {},
                    resolveTargetAtGlobalEvent: { evidence },
                    stage: { validation, operation in
                        try await withStagedPasteboardString(
                            "alpha",
                            on: pasteboard,
                            restoreClipboard: true,
                            validateBeforeStaging: validation,
                            operation: operation
                        )
                    },
                    postEvent: { _, validate in
                        try validate()
                        eventCount += 1
                    },
                    resolveVerificationTargetAfterPaste: { evidence },
                    receiptDelay: {
                        pasteboard.clearContents()
                        pasteboard.setString("bravo", forType: .string)
                        throw underlying
                    },
                    acquiresPasteboardLease: false
                )
                XCTFail("post-event failure must throw")
            } catch {
                XCTAssertEqual(error as? InsertionError, expected)
            }
            XCTAssertEqual(eventCount, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "bravo")
        }
    }

    @MainActor
    func testAsyncStagedPasteFailureRestoresExactOriginalWhileOwner() async {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)

        do {
            let _: PasteVerification = try await withStagedPasteboardString(
                "temporary async dictation",
                on: pasteboard,
                restoreClipboard: false,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                await Task.yield()
                throw InsertionError.focusChanged
            }
            XCTFail("late async failure must throw")
        } catch {
            XCTAssertEqual(error as? InsertionError, .focusChanged)
        }

        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    @MainActor
    func testAsyncStagedPasteCancellationRestoresExactOriginalWhileOwner() async throws {
        let pasteboard = makeMultiItemPasteboard()
        let original = PasteboardContentsSnapshot(pasteboard: pasteboard)
        let transaction = Task { @MainActor in
            try await withStagedPasteboardString(
                "temporary async dictation",
                on: pasteboard,
                restoreClipboard: true,
                validateBeforeStaging: {}
            ) { validateStagedOwnership in
                try validateStagedOwnership()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return .confirmed
            }
        }

        for _ in 0..<40
        where pasteboard.string(forType: .string)
            != "temporary async dictation"
        {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "temporary async dictation"
        )
        transaction.cancel()
        do {
            _ = try await transaction.value
            XCTFail("cancellation must terminate the staged transaction")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(PasteboardContentsSnapshot(pasteboard: pasteboard), original)
        assertMultiItemPasteboardWasRestored(pasteboard)
    }

    private func makeMultiItemPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.lockedinflow.tests.\(UUID().uuidString)")
        )
        let firstItem = NSPasteboardItem()
        let secondItem = NSPasteboardItem()

        XCTAssertTrue(firstItem.setData(Data("first shared".utf8), forType: .testShared))
        XCTAssertTrue(firstItem.setData(Data([0x00, 0x01, 0x02]), forType: .testFirstOnly))
        XCTAssertTrue(secondItem.setData(Data("second shared".utf8), forType: .testShared))
        XCTAssertTrue(secondItem.setData(Data([0xFE, 0xFF]), forType: .testSecondOnly))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))
        return pasteboard
    }

    private func assertMultiItemPasteboardWasRestored(
        _ pasteboard: NSPasteboard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let items = pasteboard.pasteboardItems else {
            return XCTFail("Expected restored pasteboard items", file: file, line: line)
        }
        XCTAssertEqual(items.count, 2, file: file, line: line)
        guard items.count == 2 else { return }

        XCTAssertEqual(
            items[0].types.map(\.rawValue),
            [NSPasteboard.PasteboardType.testShared, .testFirstOnly].map(\.rawValue),
            file: file,
            line: line
        )
        XCTAssertEqual(
            items[0].data(forType: .testShared),
            Data("first shared".utf8),
            file: file,
            line: line
        )
        XCTAssertEqual(
            items[0].data(forType: .testFirstOnly),
            Data([0x00, 0x01, 0x02]),
            file: file,
            line: line
        )

        XCTAssertEqual(
            items[1].types.map(\.rawValue),
            [NSPasteboard.PasteboardType.testShared, .testSecondOnly].map(\.rawValue),
            file: file,
            line: line
        )
        XCTAssertEqual(
            items[1].data(forType: .testShared),
            Data("second shared".utf8),
            file: file,
            line: line
        )
        XCTAssertEqual(
            items[1].data(forType: .testSecondOnly),
            Data([0xFE, 0xFF]),
            file: file,
            line: line
        )
    }

    // MARK: - Edit-watch value reads (opt-in learn-from-edits)

    func testEditWatchValueReadsTheCapturedControl() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit"
        )
        environment.fieldValueResult = "Pick up Jawwad from practice."
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertEqual(
            inserter.editWatchValue(of: target),
            "Pick up Jawwad from practice."
        )
    }

    func testEditWatchValueRefusesSecureFields() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit"
        )
        environment.fieldValueResult = "should never be exposed"
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)
        environment.makeFocusedControlSecure()

        XCTAssertNil(inserter.editWatchValue(of: target))
    }

    func testEnvironmentsWithoutFieldValuesDisableTheWatch() throws {
        let environment = TestInsertionEnvironment(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit"
        )
        let inserter = TextInserter(environment: environment)
        let lock = InsertionFocusLock(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit"
        )!
        let target = try inserter.captureTarget(lock)

        XCTAssertNil(inserter.editWatchValue(of: target))
    }
}

private extension NSPasteboard.PasteboardType {
    static let testShared = Self("com.lockedinflow.tests.shared")
    static let testFirstOnly = Self("com.lockedinflow.tests.first")
    static let testSecondOnly = Self("com.lockedinflow.tests.second")
}

private enum DynamicSelectedRangeReadMutation: String, CaseIterable, Equatable {
    case secureField
    case focusToSecureField
    case focusToNonsecureField
    case securityUnknown
    case applicationIdentity
    case activationGeneration
    case frontmostApplication
    case focus
    case noncollapsedRange
    case unavailableRange
}

private enum DynamicSelectedRangeReadPhase {
    case eventResolver
    case postPasteResolver
    case exactPasteReceipt
}

private final class TestInsertionEnvironment: TextInsertionEnvironment,
    @unchecked Sendable
{
    private let trusted: Bool
    private var bundleID: String
    private var appName: String?
    private var frontmostPID: pid_t?
    private let frontmostPIDAfterAXAttempt: pid_t?
    private let frontmostPIDBeforeGlobalPaste: pid_t?
    private let frontmostPIDBeforeUndo: pid_t?
    private let bundleIDBeforeGlobalPaste: String?
    private let activationGenerationBeforeGlobalPaste: UInt64?
    private let ownPID: pid_t
    private let frontmostPIDAfterFailedActivation: pid_t?
    private let frontmostPIDAfterActivation: pid_t?
    private let bundleIDAfterActivation: String?
    private var activationGeneration: UInt64
    private let activationGenerationAfterActivation: UInt64?
    private let activationDelayNanoseconds: UInt64
    private let activationChangesFrontmost: Bool
    private let activationSucceeds: Bool
    private let secureFieldAfterActivation: Bool
    private let focusedElementChangesAfterActivation: Bool
    private var focusedElementAvailable: Bool
    private let focusedElementUnavailableUnlessTargetFrontmost: Bool
    private var remainingFocusedElementUnavailableReads: Int
    private var capturedElementFocusResult: Bool? = true
    private var secureField: Bool
    private var alternateElementSecure = false
    private var secondAlternateElementSecure = false
    private var remainingDynamicSecureUnknownReads: Int
    private var dynamicSecureAlwaysUnknown: Bool
    private let dynamicSecureUnknownReadCountBeforeGlobalPaste: Int
    private let dynamicSecureAlwaysUnknownBeforeGlobalPaste: Bool
    private let selectedTextRangeCapabilityResult: Bool?
    private var remainingSelectedTextRangeCapabilityUnavailableReads: Int
    private let secureFieldAfterSelectedTextRangeCapabilityReadCount: Int?
    private let focusSwitchesToSecureAlternateAfterCapabilityReadCount: Int?
    private var selectedTextRangeResult: CFRange?
    private var remainingSelectedTextRangeUnavailableReads: Int
    private let secureFieldBeforeAXWrite: Bool
    private let focusedElementChangesBeforeAXWrite: Bool
    private let focusedElementChangesBeforeGlobalPaste: Bool
    private let secureFieldBeforePasteboardStaging: Bool
    private let selectedTextRangeUnavailableBeforePasteboardStaging: Bool
    private let secureFieldBeforeGlobalPaste: Bool
    private let selectedTextRangeUnavailableBeforeGlobalPaste: Bool
    private let secureFieldBeforePostPasteVerification: Bool
    private let bundleIDBeforePostPasteVerification: String?
    private let frontmostPIDBeforePostPasteVerification: pid_t?
    private let activationGenerationBeforePostPasteVerification: UInt64?
    private let postPasteMissingFocusedElementAttempts: Int
    private let postPasteMissingSelectedTextRangeAttempts: Int
    private let selectedRangeMutationAtEventResolver: DynamicSelectedRangeReadMutation?
    private let selectedRangeMutationAtPostPasteResolver: DynamicSelectedRangeReadMutation?
    private let selectedRangeMutationDuringExactAXEvidenceRead: DynamicSelectedRangeReadMutation?
    private let selectedRangeMutationDuringExactPasteEvidenceRead: DynamicSelectedRangeReadMutation?
    private let selectedRangeMutationDuringExactPasteReceiptRead: DynamicSelectedRangeReadMutation?
    private let securityUnknownBeforeExactPasteUnavailableReceipt: Bool
    private let focusedElementChangesAfterReadCount: Int?
    private var focusedElementAlternatesOnEveryRead: Bool
    private let focusSwitchesToSecureAlternateDuringFinalEventSecurityRead: Bool
    private let focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount: Int?
    private let queueActivationGenerationChangeAfterEventEvidence: Bool
    private let queueCaptureLeaseInvalidationAfterDescriptorRead: Bool
    private let queueExternalActivationAfterDescriptorRead: Bool
    private let activationGenerationChangeReadCount: Int?
    private let activationGenerationChangesAfterGenerationReadCount: Int?
    private let secureFieldAfterFocusedElementReadCount: Int?
    private let axInsertionVerification: AXInsertionVerification
    private var simulatedPasteboardChangeCount: Int
    private let pasteboardChangeCountAfterAXAttempt: Int?
    private let pasteVerification: PasteVerification
    private let postPasteVerificationDelayNanoseconds: UInt64
    private let element = AXUIElementCreateSystemWide()
    private let alternateElement = AXUIElementCreateApplication(84)
    private let secondAlternateElement = AXUIElementCreateApplication(85)
    private let windowElement = AXUIElementCreateApplication(142)
    private let alternateWindowElement = AXUIElementCreateApplication(143)
    private let alternateUsesDifferentWindow: Bool
    private let alternateSemanticIdentifier: String?
    private let dynamicControlDescriptorAvailable: Bool
    private var remainingDynamicControlDescriptorUnavailableReads: Int
    private var focusedElementChanged = false
    private var focusedElementChangedTwice = false
    private var isResolvingPostPasteTarget = false
    private var remainingPostPasteMissingFocusedElementAttempts: Int
    private var remainingPostPasteMissingSelectedTextRangeAttempts: Int
    private var armedSelectedRangeMutation: DynamicSelectedRangeReadMutation?
    private var armedSelectedRangeMutationPhase: DynamicSelectedRangeReadPhase?
    private var dynamicSecurityReadsBeforeFinalSecureFocusSwitch: Int?
    private var secureAlternateFocusSwitchAfterReadCount: Int?
    private(set) var focusedElementReadCount = 0
    private(set) var activationGenerationReadCount = 0
    private(set) var selectedTextRangeCapabilityReadCount = 0
    private(set) var dynamicSecureClassificationReadCount = 0
    private(set) var dynamicControlDescriptorReadCount = 0
    private(set) var selectedTextRangeReadCount = 0
    private(set) var eventResolverRangeMutationCount = 0
    private(set) var postPasteResolverRangeMutationCount = 0
    private(set) var exactPasteReceiptRangeMutationCount = 0

    var fieldValueResult: String?

    private(set) var axInsertionAttempts = 0
    private(set) var pasteboardChangeCountReads = 0
    private(set) var pastePreparationAttempts = 0
    private(set) var preStagingValidationAttempts = 0
    private(set) var pasteAttempts = 0
    private(set) var pasteTargetPID: pid_t?
    private(set) var postPasteVerificationAttempts = 0
    private(set) var undoPreparationAttempts = 0
    private(set) var undoAttempts = 0
    private(set) var activationAttempts = 0
    private(set) var preCaptureActivationRequests = 0
    private(set) var captureLeaseIsValid = true

    var originalElementIsSecure: Bool { rawSecureField(element) }
    var alternateElementIsSecure: Bool { rawSecureField(alternateElement) }
    var secondAlternateElementIsSecure: Bool {
        rawSecureField(secondAlternateElement)
    }

    init(
        trusted: Bool = true,
        bundleID: String,
        appName: String? = nil,
        frontmostPID: pid_t? = 42,
        frontmostPIDAfterAXAttempt: pid_t? = nil,
        frontmostPIDBeforeGlobalPaste: pid_t? = nil,
        frontmostPIDBeforeUndo: pid_t? = nil,
        bundleIDBeforeGlobalPaste: String? = nil,
        activationGenerationBeforeGlobalPaste: UInt64? = nil,
        ownPID: pid_t = 999,
        frontmostPIDAfterFailedActivation: pid_t? = nil,
        frontmostPIDAfterActivation: pid_t? = nil,
        bundleIDAfterActivation: String? = nil,
        currentActivationGeneration: UInt64 = 0,
        activationGenerationAfterActivation: UInt64? = nil,
        activationDelayNanoseconds: UInt64 = 0,
        activationChangesFrontmost: Bool = true,
        activationSucceeds: Bool = true,
        secureFieldAfterActivation: Bool = false,
        focusedElementChangesAfterActivation: Bool = false,
        focusedElementAvailable: Bool = true,
        focusedElementUnavailableUnlessTargetFrontmost: Bool = false,
        focusedElementUnavailableReadCount: Int = 0,
        currentElementFocusResult: Bool? = true,
        secureField: Bool = false,
        dynamicSecureUnknownReadCount: Int = 0,
        dynamicSecureAlwaysUnknown: Bool = false,
        dynamicSecureUnknownReadCountBeforeGlobalPaste: Int = 0,
        dynamicSecureAlwaysUnknownBeforeGlobalPaste: Bool = false,
        selectedTextRangeSupported: Bool? = true,
        selectedTextRangeCapabilityUnavailableReadCount: Int = 0,
        secureFieldAfterSelectedTextRangeCapabilityReadCount: Int? = nil,
        focusSwitchesToSecureAlternateAfterCapabilityReadCount: Int? = nil,
        selectedTextRange: CFRange? = CFRange(location: 0, length: 0),
        selectedTextRangeUnavailableReadCount: Int = 0,
        secureFieldBeforeAXWrite: Bool = false,
        focusedElementChangesBeforeAXWrite: Bool = false,
        focusedElementChangesBeforeGlobalPaste: Bool = false,
        secureFieldBeforePasteboardStaging: Bool = false,
        selectedTextRangeUnavailableBeforePasteboardStaging: Bool = false,
        secureFieldBeforeGlobalPaste: Bool = false,
        selectedTextRangeUnavailableBeforeGlobalPaste: Bool = false,
        secureFieldBeforePostPasteVerification: Bool = false,
        bundleIDBeforePostPasteVerification: String? = nil,
        frontmostPIDBeforePostPasteVerification: pid_t? = nil,
        activationGenerationBeforePostPasteVerification: UInt64? = nil,
        postPasteMissingFocusedElementAttempts: Int = 0,
        postPasteMissingSelectedTextRangeAttempts: Int = 0,
        selectedRangeMutationAtEventResolver:
            DynamicSelectedRangeReadMutation? = nil,
        selectedRangeMutationAtPostPasteResolver:
            DynamicSelectedRangeReadMutation? = nil,
        selectedRangeMutationDuringExactAXEvidenceRead:
            DynamicSelectedRangeReadMutation? = nil,
        selectedRangeMutationDuringExactPasteEvidenceRead:
            DynamicSelectedRangeReadMutation? = nil,
        selectedRangeMutationDuringExactPasteReceiptRead:
            DynamicSelectedRangeReadMutation? = nil,
        securityUnknownBeforeExactPasteUnavailableReceipt: Bool = false,
        focusedElementChangesAfterReadCount: Int? = nil,
        focusedElementAlternatesOnEveryRead: Bool = false,
        focusSwitchesToSecureAlternateDuringFinalEventSecurityRead: Bool = false,
        focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount:
            Int? = nil,
        queueActivationGenerationChangeAfterEventEvidence: Bool = false,
        queueCaptureLeaseInvalidationAfterDescriptorRead: Bool = false,
        queueExternalActivationAfterDescriptorRead: Bool = false,
        alternateUsesDifferentWindow: Bool = false,
        alternateSemanticIdentifier: String? = nil,
        dynamicControlDescriptorAvailable: Bool = true,
        dynamicControlDescriptorUnavailableReadCount: Int = 0,
        activationGenerationChangeReadCount: Int? = nil,
        activationGenerationChangesAfterGenerationReadCount: Int? = nil,
        secureFieldAfterFocusedElementReadCount: Int? = nil,
        axInsertionSucceeds: Bool = false,
        axInsertionVerification: AXInsertionVerification? = nil,
        pasteboardChangeCount: Int = 0,
        pasteboardChangeCountAfterAXAttempt: Int? = nil,
        pasteVerification: PasteVerification = .confirmed,
        postPasteVerificationDelayNanoseconds: UInt64 = 0
    ) {
        self.trusted = trusted
        self.bundleID = bundleID
        self.appName = appName
        self.frontmostPID = frontmostPID
        self.frontmostPIDAfterAXAttempt = frontmostPIDAfterAXAttempt
        self.frontmostPIDBeforeGlobalPaste = frontmostPIDBeforeGlobalPaste
        self.frontmostPIDBeforeUndo = frontmostPIDBeforeUndo
        self.bundleIDBeforeGlobalPaste = bundleIDBeforeGlobalPaste
        self.activationGenerationBeforeGlobalPaste =
            activationGenerationBeforeGlobalPaste
        self.ownPID = ownPID
        self.frontmostPIDAfterFailedActivation = frontmostPIDAfterFailedActivation
        self.frontmostPIDAfterActivation = frontmostPIDAfterActivation
        self.bundleIDAfterActivation = bundleIDAfterActivation
        self.activationGeneration = currentActivationGeneration
        self.activationGenerationAfterActivation = activationGenerationAfterActivation
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.activationChangesFrontmost = activationChangesFrontmost
        self.activationSucceeds = activationSucceeds
        self.secureFieldAfterActivation = secureFieldAfterActivation
        self.focusedElementChangesAfterActivation = focusedElementChangesAfterActivation
        self.focusedElementAvailable = focusedElementAvailable
        self.focusedElementUnavailableUnlessTargetFrontmost =
            focusedElementUnavailableUnlessTargetFrontmost
        self.remainingFocusedElementUnavailableReads =
            focusedElementUnavailableReadCount
        self.capturedElementFocusResult = currentElementFocusResult
        self.secureField = secureField
        self.remainingDynamicSecureUnknownReads = dynamicSecureUnknownReadCount
        self.dynamicSecureAlwaysUnknown = dynamicSecureAlwaysUnknown
        self.dynamicSecureUnknownReadCountBeforeGlobalPaste =
            dynamicSecureUnknownReadCountBeforeGlobalPaste
        self.dynamicSecureAlwaysUnknownBeforeGlobalPaste =
            dynamicSecureAlwaysUnknownBeforeGlobalPaste
        self.selectedTextRangeCapabilityResult = selectedTextRangeSupported
        self.remainingSelectedTextRangeCapabilityUnavailableReads =
            selectedTextRangeCapabilityUnavailableReadCount
        self.secureFieldAfterSelectedTextRangeCapabilityReadCount =
            secureFieldAfterSelectedTextRangeCapabilityReadCount
        self.focusSwitchesToSecureAlternateAfterCapabilityReadCount =
            focusSwitchesToSecureAlternateAfterCapabilityReadCount
        self.selectedTextRangeResult = selectedTextRange
        self.remainingSelectedTextRangeUnavailableReads =
            selectedTextRangeUnavailableReadCount
        self.secureFieldBeforeAXWrite = secureFieldBeforeAXWrite
        self.focusedElementChangesBeforeAXWrite = focusedElementChangesBeforeAXWrite
        self.focusedElementChangesBeforeGlobalPaste = focusedElementChangesBeforeGlobalPaste
        self.secureFieldBeforePasteboardStaging = secureFieldBeforePasteboardStaging
        self.selectedTextRangeUnavailableBeforePasteboardStaging =
            selectedTextRangeUnavailableBeforePasteboardStaging
        self.secureFieldBeforeGlobalPaste = secureFieldBeforeGlobalPaste
        self.selectedTextRangeUnavailableBeforeGlobalPaste =
            selectedTextRangeUnavailableBeforeGlobalPaste
        self.secureFieldBeforePostPasteVerification =
            secureFieldBeforePostPasteVerification
        self.bundleIDBeforePostPasteVerification =
            bundleIDBeforePostPasteVerification
        self.frontmostPIDBeforePostPasteVerification =
            frontmostPIDBeforePostPasteVerification
        self.activationGenerationBeforePostPasteVerification =
            activationGenerationBeforePostPasteVerification
        self.postPasteMissingFocusedElementAttempts =
            postPasteMissingFocusedElementAttempts
        self.postPasteMissingSelectedTextRangeAttempts =
            postPasteMissingSelectedTextRangeAttempts
        self.selectedRangeMutationAtEventResolver =
            selectedRangeMutationAtEventResolver
        self.selectedRangeMutationAtPostPasteResolver =
            selectedRangeMutationAtPostPasteResolver
        self.selectedRangeMutationDuringExactAXEvidenceRead =
            selectedRangeMutationDuringExactAXEvidenceRead
        self.selectedRangeMutationDuringExactPasteEvidenceRead =
            selectedRangeMutationDuringExactPasteEvidenceRead
        self.selectedRangeMutationDuringExactPasteReceiptRead =
            selectedRangeMutationDuringExactPasteReceiptRead
        self.securityUnknownBeforeExactPasteUnavailableReceipt =
            securityUnknownBeforeExactPasteUnavailableReceipt
        self.remainingPostPasteMissingFocusedElementAttempts =
            postPasteMissingFocusedElementAttempts
        self.remainingPostPasteMissingSelectedTextRangeAttempts =
            postPasteMissingSelectedTextRangeAttempts
        self.focusedElementChangesAfterReadCount = focusedElementChangesAfterReadCount
        self.focusedElementAlternatesOnEveryRead = focusedElementAlternatesOnEveryRead
        self.focusSwitchesToSecureAlternateDuringFinalEventSecurityRead =
            focusSwitchesToSecureAlternateDuringFinalEventSecurityRead
        self.focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount =
            focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount
        self.queueActivationGenerationChangeAfterEventEvidence =
            queueActivationGenerationChangeAfterEventEvidence
        self.queueCaptureLeaseInvalidationAfterDescriptorRead =
            queueCaptureLeaseInvalidationAfterDescriptorRead
        self.queueExternalActivationAfterDescriptorRead =
            queueExternalActivationAfterDescriptorRead
        self.alternateUsesDifferentWindow = alternateUsesDifferentWindow
        self.alternateSemanticIdentifier = alternateSemanticIdentifier
        self.dynamicControlDescriptorAvailable =
            dynamicControlDescriptorAvailable
        self.remainingDynamicControlDescriptorUnavailableReads =
            dynamicControlDescriptorUnavailableReadCount
        self.activationGenerationChangeReadCount = activationGenerationChangeReadCount
        self.activationGenerationChangesAfterGenerationReadCount =
            activationGenerationChangesAfterGenerationReadCount
        self.secureFieldAfterFocusedElementReadCount =
            secureFieldAfterFocusedElementReadCount
        self.axInsertionVerification =
            axInsertionVerification
            ?? (axInsertionSucceeds ? .confirmed : .notAttempted)
        self.simulatedPasteboardChangeCount = pasteboardChangeCount
        self.pasteboardChangeCountAfterAXAttempt =
            pasteboardChangeCountAfterAXAttempt
        self.pasteVerification = pasteVerification
        self.postPasteVerificationDelayNanoseconds =
            postPasteVerificationDelayNanoseconds
    }

    func isTrusted() -> Bool { trusted }

    func bundleIdentifier(for pid: pid_t) -> String { bundleID }

    func appName(for pid: pid_t) -> String? { appName }

    func frontmostProcessIdentifier() -> pid_t? { frontmostPID }

    func ownProcessIdentifier() -> pid_t { ownPID }

    @MainActor
    func activateApplication(
        processIdentifier: pid_t,
        targetElement: AXUIElement
    ) async throws -> Bool {
        try await simulateActivation(processIdentifier: processIdentifier)
    }

    @MainActor
    func requestApplicationActivation(processIdentifier: pid_t) async throws {
        try Task.checkCancellation()
        preCaptureActivationRequests += 1
        _ = try await simulateActivation(processIdentifier: processIdentifier)
    }

    @MainActor
    private func simulateActivation(processIdentifier: pid_t) async throws -> Bool {
        try Task.checkCancellation()
        activationAttempts += 1
        if activationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: activationDelayNanoseconds)
        }
        try Task.checkCancellation()
        guard activationSucceeds else {
            frontmostPID = frontmostPIDAfterFailedActivation ?? frontmostPID
            if secureFieldAfterActivation {
                secureField = true
            }
            if focusedElementChangesAfterActivation {
                focusedElementChanged = true
            }
            if let activationGenerationAfterActivation {
                activationGeneration = activationGenerationAfterActivation
            }
            return false
        }
        if activationChangesFrontmost {
            frontmostPID = processIdentifier
        }
        if let frontmostPIDAfterActivation {
            frontmostPID = frontmostPIDAfterActivation
        }
        if let bundleIDAfterActivation {
            bundleID = bundleIDAfterActivation
        }
        if secureFieldAfterActivation {
            secureField = true
        }
        if focusedElementChangesAfterActivation {
            focusedElementChanged = true
        }
        if let activationGenerationAfterActivation {
            activationGeneration = activationGenerationAfterActivation
        }
        return true
    }

    func currentActivationGeneration() -> UInt64 {
        activationGenerationReadCount += 1
        if let threshold = activationGenerationChangesAfterGenerationReadCount,
            activationGenerationReadCount > threshold
        {
            activationGeneration = 1
        }
        return activationGeneration
    }

    func showOwnWindow(afterActivationGeneration generation: UInt64) {
        frontmostPID = ownPID
        activationGeneration = generation
    }

    func showExternalApplication(
        processIdentifier: pid_t,
        activationGeneration: UInt64
    ) {
        frontmostPID = processIdentifier
        self.activationGeneration = activationGeneration
    }

    func focusedElement(for pid: pid_t) -> AXUIElement? {
        focusedElementReadCount += 1
        if focusedElementUnavailableUnlessTargetFrontmost,
            frontmostPID != pid
        {
            return nil
        }
        if remainingFocusedElementUnavailableReads > 0 {
            remainingFocusedElementUnavailableReads -= 1
            return nil
        }
        if isResolvingPostPasteTarget,
            remainingPostPasteMissingFocusedElementAttempts > 0
        {
            remainingPostPasteMissingFocusedElementAttempts -= 1
            return nil
        }
        guard focusedElementAvailable else { return nil }
        if let threshold = activationGenerationChangeReadCount,
            focusedElementReadCount > threshold
        {
            activationGeneration = 1
        }
        if let threshold = secureFieldAfterFocusedElementReadCount,
            focusedElementReadCount > threshold
        {
            secureField = true
        }
        if focusedElementAlternatesOnEveryRead {
            return focusedElementReadCount.isMultiple(of: 2)
                ? alternateElement
                : element
        }
        if let threshold = focusedElementChangesAfterReadCount,
            focusedElementReadCount > threshold
        {
            focusedElementChanged = true
        }
        if focusedElementChangedTwice {
            return secondAlternateElement
        }
        return focusedElementChanged ? alternateElement : element
    }

    func isElementFocused(_ element: AXUIElement) -> Bool? {
        guard capturedElementFocusResult == true else {
            return capturedElementFocusResult
        }
        if focusedElementAlternatesOnEveryRead { return true }
        if focusedElementChangedTwice {
            return CFEqual(element, secondAlternateElement)
        }
        if focusedElementChanged {
            return CFEqual(element, alternateElement)
        }
        return capturedElementFocusResult
    }

    private func rawSecureField(_ element: AXUIElement) -> Bool {
        secureField
            || (alternateElementSecure && CFEqual(element, alternateElement))
            || (secondAlternateElementSecure
                && CFEqual(element, secondAlternateElement))
    }

    func supportsSelectedTextRange(_ element: AXUIElement) -> Bool? {
        selectedTextRangeCapabilityReadCount += 1
        if let threshold = secureFieldAfterSelectedTextRangeCapabilityReadCount,
            selectedTextRangeCapabilityReadCount > threshold
        {
            secureField = true
        }
        if let threshold = focusSwitchesToSecureAlternateAfterCapabilityReadCount,
            selectedTextRangeCapabilityReadCount > threshold
        {
            focusedElementChanged = true
            alternateElementSecure = true
        }
        if remainingSelectedTextRangeCapabilityUnavailableReads > 0 {
            remainingSelectedTextRangeCapabilityUnavailableReads -= 1
            return nil
        }
        return selectedTextRangeCapabilityResult
    }

    func secureFieldClassification(
        _ element: AXUIElement,
        textCapabilityKnown: Bool
    ) -> SecureFieldClassification {
        dynamicSecureClassificationReadCount += 1
        if dynamicSecureAlwaysUnknown {
            return .unknown
        }
        if remainingDynamicSecureUnknownReads > 0 {
            remainingDynamicSecureUnknownReads -= 1
            return .unknown
        }
        let classification: SecureFieldClassification =
            rawSecureField(element)
            ? .secure
            : .nonsecure
        if let threshold =
            focusSwitchesToSecondSecureAlternateAfterDynamicSecurityReadCount,
            dynamicSecureClassificationReadCount > threshold
        {
            focusedElementChangedTwice = true
            secondAlternateElementSecure = true
        }
        if let threshold = secureAlternateFocusSwitchAfterReadCount,
            dynamicSecureClassificationReadCount > threshold
        {
            secureAlternateFocusSwitchAfterReadCount = nil
            focusedElementChanged = true
            alternateElementSecure = true
        }
        if let remaining = dynamicSecurityReadsBeforeFinalSecureFocusSwitch {
            if remaining == 0 {
                dynamicSecurityReadsBeforeFinalSecureFocusSwitch = nil
                focusedElementChanged = true
                alternateElementSecure = true
            } else {
                dynamicSecurityReadsBeforeFinalSecureFocusSwitch = remaining - 1
            }
        }
        return classification
    }

    func dynamicControlDescriptor(
        of element: AXUIElement
    ) -> DynamicControlDescriptor? {
        dynamicControlDescriptorReadCount += 1
        if queueCaptureLeaseInvalidationAfterDescriptorRead,
            dynamicControlDescriptorReadCount == 1
        {
            Task { @MainActor [weak self] in
                self?.captureLeaseIsValid = false
            }
        }
        if queueExternalActivationAfterDescriptorRead,
            dynamicControlDescriptorReadCount == 1
        {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showExternalApplication(
                    processIdentifier: 84,
                    activationGeneration: self.activationGeneration &+ 1
                )
            }
        }
        if remainingDynamicControlDescriptorUnavailableReads > 0 {
            remainingDynamicControlDescriptorUnavailableReads -= 1
            return nil
        }
        guard dynamicControlDescriptorAvailable else { return nil }
        let isAlternate =
            CFEqual(element, alternateElement)
            || CFEqual(element, secondAlternateElement)
        let window =
            isAlternate && alternateUsesDifferentWindow
            ? alternateWindowElement
            : windowElement
        let identifier =
            isAlternate
            ? (alternateSemanticIdentifier ?? "composer")
            : "composer"
        return DynamicControlDescriptor(
            window: window,
            semanticSignature: .normalizedComposer(
                leafSubrole: nil,
                leafIdentifier: identifier,
                ancestors: [
                    .init(
                        role: "AXGroup",
                        subrole: nil,
                        identifier: "composer-container"
                    )
                ]
            )
        )
    }

    func selectedTextRange(of element: AXUIElement) -> CFRange? {
        selectedTextRangeReadCount += 1
        if remainingSelectedTextRangeUnavailableReads > 0 {
            remainingSelectedTextRangeUnavailableReads -= 1
            return nil
        }
        if let mutation = armedSelectedRangeMutation {
            let phase = armedSelectedRangeMutationPhase
            armedSelectedRangeMutation = nil
            armedSelectedRangeMutationPhase = nil
            switch phase {
            case .eventResolver:
                eventResolverRangeMutationCount += 1
            case .postPasteResolver:
                postPasteResolverRangeMutationCount += 1
            case .exactPasteReceipt:
                exactPasteReceiptRangeMutationCount += 1
            case nil:
                break
            }

            // Return the observation made by this exact AX range read, then
            // mutate policy state before the resolver's post-read checks. This
            // deterministically models a target transition during the real
            // read/check boundary rather than before the resolver begins.
            switch mutation {
            case .secureField:
                secureField = true
            case .focusToSecureField:
                focusedElementChanged = true
                alternateElementSecure = true
            case .focusToNonsecureField:
                focusedElementChanged = true
            case .securityUnknown:
                dynamicSecureAlwaysUnknown = true
            case .applicationIdentity:
                bundleID = "com.example.replacement"
            case .activationGeneration:
                activationGeneration &+= 1
            case .frontmostApplication:
                frontmostPID = 84
            case .focus:
                capturedElementFocusResult = false
            case .noncollapsedRange:
                return CFRange(location: 0, length: 1)
            case .unavailableRange:
                return nil
            }
        }
        if isResolvingPostPasteTarget,
            remainingPostPasteMissingSelectedTextRangeAttempts > 0
        {
            remainingPostPasteMissingSelectedTextRangeAttempts -= 1
            return nil
        }
        return selectedTextRangeResult
    }

    func fieldValue(of element: AXUIElement) -> String? { fieldValueResult }

    func pasteboardChangeCount() -> Int {
        pasteboardChangeCountReads += 1
        return simulatedPasteboardChangeCount
    }

    func focusAlternateControl() {
        focusedElementChanged = true
    }

    func enableFocusedElementAlternation() {
        focusedElementAlternatesOnEveryRead = true
    }

    func removeFocusedControl() {
        focusedElementAvailable = false
    }

    func omitApplicationFocusedElement(capturedControlFocus: Bool?) {
        focusedElementAvailable = false
        capturedElementFocusResult = capturedControlFocus
    }

    func makeFocusedControlSecure() {
        secureField = true
    }

    func makeSecurityUnverifiable() {
        dynamicSecureAlwaysUnknown = true
    }

    func armSecureAlternateFocusSwitch(afterSecurityReads: Int) {
        dynamicSecureClassificationReadCount = 0
        secureAlternateFocusSwitchAfterReadCount = afterSecurityReads
    }

    func insertViaSelectedText(
        _ text: String,
        into element: AXUIElement,
        validateBeforeWrite: () throws -> Void,
        commitDelivery: () throws -> Void
    ) throws -> AXInsertionVerification {
        if secureFieldBeforeAXWrite {
            secureField = true
        }
        if focusedElementChangesBeforeAXWrite {
            focusedElementChanged = true
        }
        try validateBeforeWrite()
        armedSelectedRangeMutation =
            selectedRangeMutationDuringExactAXEvidenceRead
        defer { armedSelectedRangeMutation = nil }
        _ = selectedTextRange(of: element)
        // Mirrors MacTextInsertionEnvironment's literal setter boundary: the
        // target validator runs again after the blocking evidence read.
        try validateBeforeWrite()
        if axInsertionVerification != .notAttempted {
            try commitDelivery()
            axInsertionAttempts += 1
        }
        if let frontmostPIDAfterAXAttempt {
            frontmostPID = frontmostPIDAfterAXAttempt
        }
        if let pasteboardChangeCountAfterAXAttempt {
            simulatedPasteboardChangeCount = pasteboardChangeCountAfterAXAttempt
        }
        return axInsertionVerification
    }

    func pasteboardInsert(
        _ text: String,
        into element: AXUIElement,
        targetPID: pid_t,
        restoreClipboard: Bool,
        pasteboardLeaseAlreadyHeld: Bool,
        validateBeforeStaging: () throws -> Void,
        validateBeforeGlobalEvent: () throws -> Void,
        commitDelivery: () throws -> Void,
        resolveTargetAtGlobalEvent: (() throws -> DynamicPasteTargetEvidence)?,
        resolveVerificationTargetAfterPaste: (() throws -> DynamicPasteTargetEvidence?)?
    ) throws -> PasteVerification {
        let acquiredLease = !pasteboardLeaseAlreadyHeld
        if acquiredLease,
            !PasteboardTransactionGate.shared.tryAcquire()
        {
            throw InsertionError.insertionRejected
        }
        defer {
            if acquiredLease {
                PasteboardTransactionGate.shared.release()
            }
        }
        pastePreparationAttempts += 1
        pasteTargetPID = targetPID
        if secureFieldBeforePasteboardStaging {
            secureField = true
        }
        if selectedTextRangeUnavailableBeforePasteboardStaging {
            selectedTextRangeResult = nil
        }
        preStagingValidationAttempts += 1
        try validateBeforeStaging()
        if let frontmostPIDBeforeGlobalPaste {
            frontmostPID = frontmostPIDBeforeGlobalPaste
        }
        if let bundleIDBeforeGlobalPaste {
            bundleID = bundleIDBeforeGlobalPaste
        }
        if let activationGenerationBeforeGlobalPaste {
            activationGeneration = activationGenerationBeforeGlobalPaste
        }
        if focusedElementChangesBeforeGlobalPaste {
            focusedElementChanged = true
        }
        if secureFieldBeforeGlobalPaste {
            secureField = true
        }
        if selectedTextRangeUnavailableBeforeGlobalPaste {
            selectedTextRangeResult = nil
        }
        if dynamicSecureUnknownReadCountBeforeGlobalPaste > 0 {
            remainingDynamicSecureUnknownReads =
                dynamicSecureUnknownReadCountBeforeGlobalPaste
        }
        if dynamicSecureAlwaysUnknownBeforeGlobalPaste {
            dynamicSecureAlwaysUnknown = true
        }
        try validateBeforeGlobalEvent()
        var dynamicBeforeEvidence: DynamicPasteTargetEvidence?
        var exactBeforeRange: CFRange?
        if let resolveTargetAtGlobalEvent {
            if let selectedRangeMutationAtEventResolver,
                eventResolverRangeMutationCount == 0
            {
                armedSelectedRangeMutation = selectedRangeMutationAtEventResolver
                armedSelectedRangeMutationPhase = .eventResolver
            }
            do {
                dynamicBeforeEvidence = try resolveTargetAtGlobalEvent()
            } catch {
                armedSelectedRangeMutation = nil
                armedSelectedRangeMutationPhase = nil
                throw error
            }
            armedSelectedRangeMutation = nil
            armedSelectedRangeMutationPhase = nil
        } else {
            armedSelectedRangeMutation =
                selectedRangeMutationDuringExactPasteEvidenceRead
            defer { armedSelectedRangeMutation = nil }
            exactBeforeRange = selectedTextRange(of: element)
            // Mirrors the exact production event boundary: focus/security is
            // revalidated after the AX range read and before Cmd+V.
            try validateBeforeGlobalEvent()
        }
        try commitDelivery()
        pasteAttempts += 1
        if pasteVerification == .confirmed,
            let before = dynamicBeforeEvidence?.selectedTextRange
        {
            let (afterLocation, overflowed) = before.location
                .addingReportingOverflow(text.utf16.count)
            if !overflowed {
                selectedTextRangeResult = CFRange(
                    location: afterLocation,
                    length: 0
                )
            }
        }
        if let resolveVerificationTargetAfterPaste {
            if secureFieldBeforePostPasteVerification {
                secureField = true
            }
            if let bundleIDBeforePostPasteVerification {
                bundleID = bundleIDBeforePostPasteVerification
            }
            if let frontmostPIDBeforePostPasteVerification {
                frontmostPID = frontmostPIDBeforePostPasteVerification
            }
            if let activationGenerationBeforePostPasteVerification {
                activationGeneration = activationGenerationBeforePostPasteVerification
            }
            isResolvingPostPasteTarget = true
            defer { isResolvingPostPasteTarget = false }
            let transientRangeMutationAttempts =
                selectedRangeMutationAtPostPasteResolver == .noncollapsedRange
                    || selectedRangeMutationAtPostPasteResolver == .unavailableRange
                ? 1
                : 0
            let attempts = max(
                1,
                min(
                    4,
                    max(
                        max(
                            postPasteMissingFocusedElementAttempts,
                            postPasteMissingSelectedTextRangeAttempts
                        ),
                        transientRangeMutationAttempts
                    ) + 1
                )
            )
            for _ in 0..<attempts {
                postPasteVerificationAttempts += 1
                if let selectedRangeMutationAtPostPasteResolver,
                    postPasteResolverRangeMutationCount == 0
                {
                    armedSelectedRangeMutation = selectedRangeMutationAtPostPasteResolver
                    armedSelectedRangeMutationPhase = .postPasteResolver
                }
                let evidence: DynamicPasteTargetEvidence?
                do {
                    evidence = try resolveVerificationTargetAfterPaste()
                } catch {
                    armedSelectedRangeMutation = nil
                    armedSelectedRangeMutationPhase = nil
                    throw error
                }
                armedSelectedRangeMutation = nil
                armedSelectedRangeMutationPhase = nil
                if evidence != nil {
                    return pasteVerification
                }
            }
            return .unavailable
        }
        guard exactBeforeRange != nil else {
            // Production has no receipt range to compare when the event
            // baseline was unavailable. It waits through the delivery window,
            // revalidates the exact target, and reports an unverified event
            // without inventing a second range observation.
            if securityUnknownBeforeExactPasteUnavailableReceipt {
                dynamicSecureAlwaysUnknown = true
            }
            do {
                try validateBeforeGlobalEvent()
            } catch {
                throw clipboardErrorAfterPasteEvent(error)
            }
            return .unavailable
        }
        armedSelectedRangeMutation =
            selectedRangeMutationDuringExactPasteReceiptRead
        armedSelectedRangeMutationPhase = .exactPasteReceipt
        do {
            // Mirrors the production receipt boundary after its one event:
            // prove exact focus/security on both sides of the AX range read.
            try validateBeforeGlobalEvent()
            _ = selectedTextRange(of: element)
            try validateBeforeGlobalEvent()
        } catch {
            armedSelectedRangeMutation = nil
            armedSelectedRangeMutationPhase = nil
            throw clipboardErrorAfterPasteEvent(error)
        }
        armedSelectedRangeMutation = nil
        armedSelectedRangeMutationPhase = nil
        return pasteVerification
    }

    @MainActor
    func pasteboardInsertDynamic(
        _ text: String,
        targetPID: pid_t,
        restoreClipboard: Bool,
        validateBeforeStaging: @escaping () throws -> Void,
        commitDelivery: @escaping () throws -> Void,
        resolveTargetAtGlobalEvent:
            @escaping () async throws -> DynamicPasteTargetEvidence,
        validateResolvedTargetAtGlobalEvent:
            @escaping (DynamicPasteTargetEvidence) throws -> Void,
        resolveVerificationTargetAfterPaste:
            @escaping () throws -> DynamicPasteTargetEvidence?
    ) async throws -> PasteVerification {
        pastePreparationAttempts += 1
        pasteTargetPID = targetPID

        if let frontmostPIDBeforeGlobalPaste {
            frontmostPID = frontmostPIDBeforeGlobalPaste
        }
        if let bundleIDBeforeGlobalPaste {
            bundleID = bundleIDBeforeGlobalPaste
        }
        if let activationGenerationBeforeGlobalPaste {
            activationGeneration = activationGenerationBeforeGlobalPaste
        }
        if focusedElementChangesBeforeGlobalPaste {
            focusedElementChanged = true
        }
        if secureFieldBeforeGlobalPaste {
            secureField = true
        }
        if selectedTextRangeUnavailableBeforeGlobalPaste {
            selectedTextRangeResult = nil
        }
        if dynamicSecureUnknownReadCountBeforeGlobalPaste > 0 {
            remainingDynamicSecureUnknownReads =
                dynamicSecureUnknownReadCountBeforeGlobalPaste
        }
        if dynamicSecureAlwaysUnknownBeforeGlobalPaste {
            dynamicSecureAlwaysUnknown = true
        }

        if let selectedRangeMutationAtEventResolver,
            eventResolverRangeMutationCount == 0
        {
            armedSelectedRangeMutation = selectedRangeMutationAtEventResolver
            armedSelectedRangeMutationPhase = .eventResolver
        }
        defer {
            armedSelectedRangeMutation = nil
            armedSelectedRangeMutationPhase = nil
            isResolvingPostPasteTarget = false
        }
        return try await performDynamicPasteTransport(
            text: text,
            validateBeforeStaging: validateBeforeStaging,
            resolveTargetAtGlobalEvent: {
                let evidence = try await resolveTargetAtGlobalEvent()
                if self.queueActivationGenerationChangeAfterEventEvidence {
                    Task { @MainActor in
                        self.activationGeneration &+= 1
                    }
                }
                return evidence
            },
            stage: { validation, operation in
                if self.secureFieldBeforePasteboardStaging {
                    self.secureField = true
                }
                if self.selectedTextRangeUnavailableBeforePasteboardStaging {
                    self.selectedTextRangeResult = nil
                }
                self.preStagingValidationAttempts += 1
                try validation()
                if self.focusSwitchesToSecureAlternateDuringFinalEventSecurityRead {
                    // Event validation performs five secure classifications;
                    // mutate focus while the final one still returns the old
                    // leaf's non-secure observation.
                    self.dynamicSecurityReadsBeforeFinalSecureFocusSwitch = 4
                }
                let verification = try await operation({})
                if self.pasteVerification
                    == .confirmedWithClipboardRestorationUnverified,
                    verification == .confirmed
                {
                    return .confirmedWithClipboardRestorationUnverified
                }
                return verification
            },
            postEvent: { evidence, validateStagedOwnership in
                try validateResolvedTargetAtGlobalEvent(evidence)
                try validateStagedOwnership()
                try commitDelivery()
                self.pasteAttempts += 1
                if self.pasteVerification == .confirmed
                    || self.pasteVerification
                        == .confirmedWithClipboardRestorationUnverified
                {
                    let (afterLocation, overflowed) = evidence
                        .selectedTextRange.location
                        .addingReportingOverflow(text.utf16.count)
                    if !overflowed {
                        self.selectedTextRangeResult = CFRange(
                            location: afterLocation,
                            length: 0
                        )
                    }
                }
                if self.secureFieldBeforePostPasteVerification {
                    self.secureField = true
                }
                if let bundleID = self.bundleIDBeforePostPasteVerification {
                    self.bundleID = bundleID
                }
                if let pid = self.frontmostPIDBeforePostPasteVerification {
                    self.frontmostPID = pid
                }
                if let generation = self
                    .activationGenerationBeforePostPasteVerification
                {
                    self.activationGeneration = generation
                }
                self.isResolvingPostPasteTarget = true
            },
            resolveVerificationTargetAfterPaste: {
                self.postPasteVerificationAttempts += 1
                if let mutation = self.selectedRangeMutationAtPostPasteResolver,
                    self.postPasteResolverRangeMutationCount == 0
                {
                    self.armedSelectedRangeMutation = mutation
                    self.armedSelectedRangeMutationPhase = .postPasteResolver
                }
                defer {
                    self.armedSelectedRangeMutation = nil
                    self.armedSelectedRangeMutationPhase = nil
                }
                return try resolveVerificationTargetAfterPaste()
            },
            receiptDelay: {
                if self.postPasteVerificationDelayNanoseconds > 0 {
                    try await Task.sleep(
                        nanoseconds: self.postPasteVerificationDelayNanoseconds
                    )
                } else {
                    await Task.yield()
                }
            },
            acquiresPasteboardLease: false
        )
    }

    func postUndoKeystroke(
        validateBeforeGlobalEvent: () throws -> Void
    ) throws {
        undoPreparationAttempts += 1
        if let frontmostPIDBeforeUndo {
            frontmostPID = frontmostPIDBeforeUndo
        }
        try validateBeforeGlobalEvent()
        undoAttempts += 1
    }
}
