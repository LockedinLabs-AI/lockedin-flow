import Foundation
import XCTest

final class DictationControllerSafetyPolicyTests: XCTestCase {
    private var controllerSource: String {
        get throws {
            let testFile = URL(fileURLWithPath: #filePath)
            let repository =
                testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let controller =
                repository
                .appendingPathComponent("Sources/LockedInFlowApp/DictationController.swift")
            return try String(contentsOf: controller, encoding: .utf8)
        }
    }

    private var textInserterSource: String {
        get throws {
            let testFile = URL(fileURLWithPath: #filePath)
            let repository =
                testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let inserter =
                repository
                .appendingPathComponent("Sources/InsertionEngine/TextInserter.swift")
            return try String(contentsOf: inserter, encoding: .utf8)
        }
    }

    private func appSource(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository =
            testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                repository
                .appendingPathComponent("Sources/LockedInFlowApp")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    func testAutomaticClipboardWritesRemainConditional() throws {
        let source = try controllerSource

        XCTAssertFalse(source.contains("PasteboardContentBaseline"))
        XCTAssertFalse(
            source.contains("let recoveryClipboardBaseline = PasteboardGenerationBaseline()"))
        XCTAssertTrue(source.contains("switch result.clipboardDisposition"))
        XCTAssertTrue(source.contains("== .pasteTransportRestorationUnverified"))
        XCTAssertTrue(source.contains("clipboardWriteOutcome = .outcomeUnverified"))
        XCTAssertTrue(source.contains("ifChangeCountMatches: expectedChangeCount"))
        XCTAssertFalse(source.contains(".writeStringIfUnchanged(final)"))
        XCTAssertFalse(source.contains("writeStringIfUnchangedOrExactlyRestored"))
        XCTAssertFalse(
            source.contains("let summaryClipboardBaseline = PasteboardGenerationBaseline()"))
        XCTAssertFalse(source.contains("summaryClipboardBaseline.writeStringIfUnchanged(raw)"))
        XCTAssertTrue(
            source.contains(
                "Meeting saved without a summary. The transcript remains in Meetings."
            )
        )
        XCTAssertTrue(source.contains("switch clipboardWriteOutcome"))
        XCTAssertFalse(source.contains("private func copyToClipboard"))
    }

    func testInsertionFailureRequiresExplicitRecoveryAction() throws {
        let source = try controllerSource

        XCTAssertTrue(
            source.contains(
                "// A recoverable insertion failure must not create an\n"
                    + "                    // implicit clipboard export."
            )
        )
        XCTAssertTrue(
            source.contains("clipboardWriteOutcome = .clipboardUnchanged")
        )
        XCTAssertTrue(
            source.contains(
                "The clipboard was left unchanged; the transcript remains in LockedIn Flow for retry."
            )
        )
    }

    func testOrdinaryRecordingDefersConcreteTargetUntilDelivery() throws {
        let source = try controllerSource

        XCTAssertTrue(source.contains("let targetSnapshot: InsertionTargetSnapshot"))
        XCTAssertTrue(
            source.contains(
                "var focusLock: InsertionFocusLock? { targetSnapshot?.focusLock }"
            )
        )
        XCTAssertFalse(
            source.contains("let insertionTarget: CapturedInsertionTarget?")
        )
        XCTAssertTrue(
            source.contains(
                "targetSnapshot: targetSnapshot,\n            localProfile: state.effectiveProfile,\n            deliveryMode: captureDeliveryMode,\n            captureWasInterrupted: capture.wasInterrupted"
            )
        )

        let recordingStart = try XCTUnwrap(
            source.range(of: "private func startRecording(requiresHeldHotKey:")
        )
        let recordingEnd = try XCTUnwrap(
            source.range(
                of: "private func noteLevel", range: recordingStart.upperBound..<source.endIndex)
        )
        let recordingPath = source[recordingStart.lowerBound..<recordingEnd.lowerBound]
        XCTAssertFalse(recordingPath.contains("prepareTargetForOrdinaryCapture"))
        XCTAssertFalse(recordingPath.contains("CapturedInsertionTarget"))
        XCTAssertTrue(recordingPath.contains("isExplicitSecureFieldFocused"))
        XCTAssertTrue(recordingPath.contains("if deliveryMode.requiresAccessibility,"))
        XCTAssertTrue(recordingPath.contains("guard state.deliveryMode == deliveryMode else"))
        XCTAssertFalse(recordingPath.contains("isTrusted(prompt: true)"))

        let insertionStart = try XCTUnwrap(
            source.range(of: "private func completeInsertion(")
        )
        let insertionEnd = try XCTUnwrap(
            source.range(
                of: "private func startMeeting", range: insertionStart.upperBound..<source.endIndex)
        )
        let insertionPath = source[insertionStart.lowerBound..<insertionEnd.lowerBound]
        XCTAssertTrue(insertionPath.contains("insertOrdinaryAtCurrentTarget"))
        XCTAssertFalse(insertionPath.contains("prepareTargetForOrdinaryCapture"))
        XCTAssertFalse(insertionPath.contains("restoreFocusForOrdinaryDictation"))
        XCTAssertTrue(
            insertionPath.contains("supportsExactPostDeliveryObservation")
        )
        XCTAssertTrue(
            try textInserterSource.contains(
                "guard shouldContinue() else { throw CancellationError() }"
            )
        )
        XCTAssertFalse(source.contains("capturePreflightFailureMessage"))
        XCTAssertFalse(source.contains("target field changed before recording"))
    }

    func testConfirmedPasteRestorationWarningDoesNotBecomeRetryableFailure() throws {
        let source = try controllerSource

        XCTAssertTrue(
            source.contains(
                "Delivery itself was conclusively confirmed. Keep the\n"
                    + "                // pipeline successful"
            )
        )
        XCTAssertTrue(
            source.contains(
                "Inserted. Check the clipboard before continuing because its final state could not be verified."
            )
        )
        XCTAssertTrue(
            source.contains(
                "Re-inserted. Check the clipboard before continuing because its final state could not be verified."
            )
        )
        XCTAssertTrue(
            source.contains("case .insertionAndClipboardRestorationUnverified:")
        )

        let testFile = URL(fileURLWithPath: #filePath)
        let appSources =
            testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LockedInFlowApp")
        let appState = try String(
            contentsOf: appSources.appendingPathComponent("AppState.swift"),
            encoding: .utf8
        )
        let menu = try String(
            contentsOf: appSources.appendingPathComponent("MenuBarView.swift"),
            encoding: .utf8
        )
        let home = try String(
            contentsOf: appSources.appendingPathComponent("HomeView.swift"),
            encoding: .utf8
        )
        let history = try String(
            contentsOf: appSources.appendingPathComponent("HistoryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appState.contains("Result<ReinsertSuccess, Error>"))
        XCTAssertTrue(menu.contains("state.statusMessage = outcome.statusMessage"))
        XCTAssertTrue(home.contains("reinsertionMessage = outcome.compactMessage"))
        XCTAssertTrue(history.contains("reinsertionMessage = outcome.compactMessage"))
        XCTAssertTrue(menu.contains("error is ReinsertSafetyNoticeError"))
        XCTAssertTrue(home.contains("reinsertionMessage = \"Check insertion\""))
        XCTAssertTrue(history.contains("reinsertionMessage = \"Check insertion\""))
        XCTAssertTrue(home.contains("reinsertionCanceled = true"))
        XCTAssertTrue(history.contains("reinsertionCanceled = true"))
        XCTAssertTrue(home.contains("? \"xmark\""))
        XCTAssertTrue(history.contains("? \"xmark\""))
        XCTAssertFalse(source.contains("Result<String, Error>"))
    }

    func testCancellationPrecedesRecoveryHandling() throws {
        let source = try controllerSource
        let cancellation = try XCTUnwrap(
            source.range(of: "if error is CancellationError || Task.isCancelled")
        )
        let recovery = try XCTUnwrap(
            source.range(of: "RecoveryStore.shared.record", options: .backwards)
        )

        XCTAssertLessThan(cancellation.lowerBound, recovery.lowerBound)
        XCTAssertTrue(source.contains("cancellationSafetyNotice(for: error)"))
        XCTAssertTrue(
            source.contains("insertion.requiresCancellationSafetyNotice")
        )
        XCTAssertTrue(
            source.contains(
                "Cancellation completed before a paste command was sent. Inspect the clipboard"
            )
        )
        XCTAssertTrue(
            source.contains(
                "Cancellation completed before a paste command was sent. Clear or inspect the clipboard"
            )
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "let safetyNotice = Self.cancellationSafetyNotice(for: error)"
            ).count - 1,
            2,
            "both reinsert paths must preserve terminal cancellation warnings"
        )
        XCTAssertTrue(
            source.contains(
                "Insertion completed before cancellation. Inspect the original field"
            )
        )
        XCTAssertTrue(
            source.contains(
                "if Task.isCancelled {\n"
                    + "                // Delivery is already confirmed"
            )
        )
    }

    func testApplicationActivationCannotQueueFocusTheftAfterCancellation() throws {
        let source = try textInserterSource

        XCTAssertFalse(source.contains("NSWorkspace.OpenConfiguration"))
        XCTAssertFalse(source.contains("openApplication("))
        XCTAssertFalse(source.contains("try? await Task.sleep"))
        XCTAssertTrue(source.contains("async throws -> Bool"))
        XCTAssertTrue(
            source.contains(
                "Do not queue `openApplication`: its completion is not cancellable"
            )
        )
    }

    func testReinsertTasksRemainStoredTokenizedAndCancelled() throws {
        let source = try controllerSource

        XCTAssertTrue(source.contains("private let reinsertTaskGate = ReinsertTaskGate()"))
        XCTAssertTrue(source.contains("reinsertTaskGate.attach(task, to: lease)"))
        XCTAssertTrue(source.contains("try requireCurrentReinsert(lease)"))
        XCTAssertTrue(source.contains("reinsertTaskGate.cancelAll()"))
        XCTAssertEqual(
            source.components(
                separatedBy: "self.reinsertTaskGate.commitDelivery(lease)"
            ).count - 1,
            2,
            "both reinsert entry points must mark the irreversible boundary"
        )
        XCTAssertTrue(
            source.contains(
                "let reinsertCancellationPending = reinsertTaskGate.cancelAll()"
            )
        )
        XCTAssertTrue(source.contains("state?.pipelineState = .inserting"))
        XCTAssertTrue(source.contains("insertion.requiresReinsertInspection"))
        XCTAssertTrue(
            source.contains(
                "requiringInspection: stillOwnsTask && inspectionMessage != nil"
            ),
            "terminal unknown outcomes must leave an inspection latch"
        )
        XCTAssertTrue(source.contains("state.presentReinsertInspection(notice)"))
        XCTAssertNotNil(
            source.range(
                of: #"inspectionMessage\s*=\s*Self\s*\.confirmedDeliveryCancellationSafetyNotice"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            source.range(
                of:
                    #"if\s+result\.clipboardDisposition\s*==\s*\.pasteTransportRestorationUnverified\s*\{\s*inspectionMessage\s*=\s*\"Re-inserted\."#,
                options: .regularExpression
            )
        )
        XCTAssertTrue(source.contains("if outcome.requiresInspectionAcknowledgement"))
        XCTAssertTrue(
            source.contains(
                "completion(.failure(ReinsertSafetyNoticeError(notice: notice)))"
            )
        )
        XCTAssertTrue(
            source.contains(
                "ReinsertSuccess(\n"
                    + "                        appName: appName,\n"
                    + "                        requiresClipboardInspection: result.clipboardDisposition\n"
                    + "                            == .pasteTransportRestorationUnverified,\n"
                    + "                        completedBeforeCancellation: true"
            )
        )
        XCTAssertTrue(
            source.contains(
                "removal of the staged transcript could not be verified. The original transcript remains in LockedIn Flow."
            ))
        XCTAssertTrue(
            source.contains(
                "Delivery and staged-transcript removal could not be verified; the original transcript remains in LockedIn Flow."
            ))
    }

    func testInspectionAcknowledgementIsSeparateFromReinsertAndVisibleEverywhere() throws {
        let source = try controllerSource
        let appState = try appSource("AppState.swift")
        let home = try appSource("HomeView.swift")
        let history = try appSource("HistoryView.swift")
        let menu = try appSource("MenuBarView.swift")
        let compare = try appSource("CompareView.swift")

        XCTAssertTrue(source.contains("reinsertTaskGate.acknowledgeInspection"))
        XCTAssertTrue(source.contains("state?.clearReinsertInspection(notice)"))
        XCTAssertTrue(appState.contains("@Published private(set) var pendingReinsertInspection"))
        XCTAssertTrue(appState.contains("controller.acknowledgeReinsertInspection(notice)"))
        XCTAssertTrue(appState.contains("sourceID: UUID? = nil"))
        XCTAssertFalse(appState.contains("statusMessage = \"Inspection acknowledged"))

        for view in [home, history, menu] {
            XCTAssertTrue(view.contains("Button(\"I checked\")"))
            XCTAssertTrue(view.contains("state.acknowledgeReinsertInspection(notice)"))
            XCTAssertTrue(view.contains("state.pendingReinsertInspection"))
        }
        XCTAssertTrue(home.contains("sourceID: entry.id"))
        XCTAssertTrue(history.contains("sourceID: entry.id"))
        XCTAssertTrue(menu.contains("sourceID: entry.id"))
        XCTAssertTrue(menu.contains("if !outcome.requiresInspectionAcknowledgement"))
        XCTAssertTrue(home.contains("if oldInspection != nil, newInspection == nil"))
        XCTAssertTrue(history.contains("if oldInspection != nil, newInspection == nil"))
        XCTAssertTrue(home.contains("$0.sourceID == entry.id ? $0 : nil"))
        XCTAssertTrue(history.contains("$0.sourceID == entry.id ? $0 : nil"))
        XCTAssertTrue(compare.contains("state.pendingReinsertInspection != nil"))

        let acknowledgement = try XCTUnwrap(
            source.range(of: "func acknowledgeReinsertInspection")
        )
        let nextFunction = source[acknowledgement.upperBound...]
            .range(of: "\n    func ")
        let acknowledgementBody =
            nextFunction.map {
                source[acknowledgement.lowerBound..<$0.lowerBound]
            } ?? source[acknowledgement.lowerBound...]
        XCTAssertFalse(acknowledgementBody.contains("insertOrdinary"))
        XCTAssertFalse(acknowledgementBody.contains("prepareTarget"))
        XCTAssertFalse(acknowledgementBody.contains("postCommandV"))
    }
}
