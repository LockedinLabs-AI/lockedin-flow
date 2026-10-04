import XCTest
@testable import VoiceCore

final class FirstDictationReadinessTests: XCTestCase {
    func testEveryRequirementCombinationHasAnActionableNextStep() {
        for ready in [false, true] {
            for checking in [false, true] {
                for microphone in [false, true] {
                    for accessibility in [false, true] {
                        let readiness = FirstDictationReadiness(
                            modelReady: ready,
                            modelChecking: checking,
                            microphoneAuthorized: microphone,
                            accessibilityTrusted: accessibility,
                            deliveryMode: .automaticInsertion
                        )
                        let expected: FirstDictationReadiness.NextAction
                        if checking {
                            expected = .waitForModel
                        } else if !ready {
                            expected = .setUpModel
                        } else if !microphone || !accessibility {
                            expected = .reviewPermissions
                        } else {
                            expected = .openDictation
                        }
                        XCTAssertEqual(readiness.nextAction, expected)
                        XCTAssertEqual(
                            readiness.canFinish, ready && !checking && microphone && accessibility)
                    }
                }
            }
        }
    }

    func testProvisioningThenPermissionGrantLeadsToCompletion() {
        func state(model: Bool, microphone: Bool, accessibility: Bool)
            -> FirstDictationReadiness
        {
            FirstDictationReadiness(
                modelReady: model, modelChecking: false,
                microphoneAuthorized: microphone, accessibilityTrusted: accessibility,
                deliveryMode: .automaticInsertion)
        }
        XCTAssertEqual(
            state(model: false, microphone: false, accessibility: false).nextAction, .setUpModel)
        XCTAssertEqual(
            state(model: true, microphone: false, accessibility: false).nextAction,
            .reviewPermissions)
        XCTAssertEqual(
            state(model: true, microphone: true, accessibility: false).nextAction,
            .reviewPermissions)
        XCTAssertTrue(state(model: true, microphone: true, accessibility: true).canFinish)
        XCTAssertFalse(state(model: true, microphone: false, accessibility: true).canFinish)
    }

    func testCheckingCannotFinishUsingAnEarlierReadyFlag() {
        let readiness = FirstDictationReadiness(
            modelReady: true, modelChecking: true,
            microphoneAuthorized: true, accessibilityTrusted: true)
        XCTAssertEqual(readiness.nextAction, .waitForModel)
        XCTAssertFalse(readiness.canFinish)
    }

    func testInAppSetupNeverRequiresAccessibility() {
        for ready in [false, true] {
            for checking in [false, true] {
                for microphone in [false, true] {
                    for accessibility in [false, true] {
                        let readiness = FirstDictationReadiness(
                            modelReady: ready, modelChecking: checking,
                            microphoneAuthorized: microphone,
                            accessibilityTrusted: accessibility)
                        XCTAssertEqual(readiness.canFinish, ready && !checking && microphone)
                        if ready && !checking && microphone {
                            XCTAssertEqual(readiness.nextAction, .openDictation)
                        }
                    }
                }
            }
        }
    }
}
