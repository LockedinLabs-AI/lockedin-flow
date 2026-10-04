import XCTest
@testable import VoiceCore

final class DictationDeliveryModeTests: XCTestCase {
    func testNewAndUnknownPreferencesDefaultToInApp() {
        for preference in [nil, "", "unknown", "inApp"] {
            XCTAssertEqual(DictationDeliveryMode(storedPreference: preference), .inApp)
        }
        XCTAssertEqual(
            DictationDeliveryMode(storedPreference: "automaticInsertion"), .automaticInsertion)
    }

    func testInAppRecordingRequiresOnlyMicrophonePermission() {
        for accessibility in [false, true] {
            XCTAssertTrue(
                DictationDeliveryMode.inApp.canRecord(
                    microphoneAuthorized: true, accessibilityTrusted: accessibility))
            XCTAssertFalse(
                DictationDeliveryMode.inApp.canRecord(
                    microphoneAuthorized: false, accessibilityTrusted: accessibility))
        }
        XCTAssertFalse(DictationDeliveryMode.inApp.requiresAccessibility)
    }

    func testAutomaticInsertionRequiresBothPermissions() {
        for microphone in [false, true] {
            for accessibility in [false, true] {
                XCTAssertEqual(
                    DictationDeliveryMode.automaticInsertion.canRecord(
                        microphoneAuthorized: microphone, accessibilityTrusted: accessibility),
                    microphone && accessibility)
            }
        }
    }

    func testPermissionPromptRequiresTheCorrectPackagedIdentity() {
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(bundleIdentifier: nil))
        XCTAssertFalse(permits(bundleIdentifier: "com.privateflow.app"))
        XCTAssertFalse(permits(bundleName: "privateflow"))
        XCTAssertFalse(permits(displayName: "Private Flow"))
        XCTAssertFalse(permits(displayName: nil))
        XCTAssertFalse(permits(executableName: "privateflow"))
        XCTAssertFalse(permits(runningExecutableName: "lockedin-flow"))
        XCTAssertFalse(permits(isApplicationBundle: false))
    }

    private func permits(
        bundleIdentifier: String? = "ai.lockedin.flow.community",
        bundleName: String? = "LockedIn Flow",
        displayName: String? = "LockedIn Flow",
        executableName: String? = "LockedInFlow",
        runningExecutableName: String? = "LockedInFlow",
        isApplicationBundle: Bool = true
    ) -> Bool {
        AccessibilityRequestIdentity.permitsPrompt(
            bundleIdentifier: bundleIdentifier, bundleName: bundleName,
            displayName: displayName, executableName: executableName,
            runningExecutableName: runningExecutableName,
            isApplicationBundle: isApplicationBundle)
    }
}
