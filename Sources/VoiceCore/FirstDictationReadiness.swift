/// Read-only first-run guidance. Resolving a requirement never grants permission,
/// loads a model, or begins recording; the application performs explicit actions.
public struct FirstDictationReadiness: Equatable, Sendable {
    public enum NextAction: Equatable, Sendable {
        case waitForModel
        case setUpModel
        case reviewPermissions
        case openDictation
    }

    public let modelReady: Bool
    public let modelChecking: Bool
    public let microphoneAuthorized: Bool
    public let accessibilityTrusted: Bool
    public let deliveryMode: DictationDeliveryMode

    public init(
        modelReady: Bool,
        modelChecking: Bool,
        microphoneAuthorized: Bool,
        accessibilityTrusted: Bool,
        deliveryMode: DictationDeliveryMode = .inApp
    ) {
        self.modelReady = modelReady
        self.modelChecking = modelChecking
        self.microphoneAuthorized = microphoneAuthorized
        self.accessibilityTrusted = accessibilityTrusted
        self.deliveryMode = deliveryMode
    }

    public var nextAction: NextAction {
        if modelChecking { return .waitForModel }
        if !modelReady { return .setUpModel }
        if !deliveryMode.canRecord(
            microphoneAuthorized: microphoneAuthorized,
            accessibilityTrusted: accessibilityTrusted
        ) {
            return .reviewPermissions
        }
        return .openDictation
    }

    public var canFinish: Bool { nextAction == .openDictation }
}
