/// Local transcription is the least-privilege default. Existing Accessibility
/// grants are not consent to enable automatic insertion in this application.
public enum DictationDeliveryMode: String, Sendable {
    case inApp
    case automaticInsertion

    public init(storedPreference: String?) {
        self = storedPreference.flatMap(Self.init(rawValue:)) ?? .inApp
    }

    public var requiresAccessibility: Bool { self == .automaticInsertion }

    public func canRecord(microphoneAuthorized: Bool, accessibilityTrusted: Bool) -> Bool {
        microphoneAuthorized && (!requiresAccessibility || accessibilityTrusted)
    }
}

/// Do not attribute a sensitive permission request to a terminal executable,
/// legacy identity, helper, or incorrectly assembled application bundle.
public enum AccessibilityRequestIdentity {
    public static func permitsPrompt(
        bundleIdentifier: String?,
        bundleName: String?,
        displayName: String?,
        executableName: String?,
        runningExecutableName: String?,
        isApplicationBundle: Bool
    ) -> Bool {
        isApplicationBundle
            && bundleIdentifier == "ai.lockedin.flow.community"
            && bundleName == "LockedIn Flow"
            && displayName == "LockedIn Flow"
            && executableName == "LockedInFlow"
            && runningExecutableName == "LockedInFlow"
    }
}
