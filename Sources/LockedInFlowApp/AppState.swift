import AppKit
import AudioCapture
import AVFoundation
import Combine
import InsertionEngine
import KeyboardShortcuts
import SpeechEngine
import SwiftUI
import TextIntelligence
import VoiceCore

/// A just-learned vocabulary correction surfaced for confirmation and undo.
struct VocabularyToast: Equatable {
    let message: String
    let ruleID: UUID
}

/// Central observable state for the menu bar, overlay, and settings.
@MainActor
final class AppState: ObservableObject {
    enum OverlayTone {
        case recording, working, success, failure
    }

    /// One source of truth for every prominent dictation control. Keeping this
    /// semantic (rather than view-specific) prevents the Home window, menu, and
    /// floating bar from advertising recording while an action is unavailable.
    enum PrimaryDictationAction: Equatable {
        case start
        case finish
        case retry
        case preparingModel
        case retryModel
        case requestMicrophone
        case requestAccessibility
        case working

        var isEnabled: Bool {
            switch self {
            case .preparingModel, .working:
                return false
            default:
                return true
            }
        }
    }

    // Pipeline
    @Published var pipelineState: PipelineState = .idle
    @Published var overlayTone: OverlayTone = .recording
    @Published var level: Float = 0
    @Published var recordingStartedAt: Date? = nil

    // Floating bar
    @Published var barVisibility: BarVisibility {
        didSet { UserDefaults.standard.set(barVisibility.rawValue, forKey: "barVisibility") }
    }
    @Published var autoCopyEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCopyEnabled, forKey: "autoCopyEnabled") }
    }
    /// Seconds of silence before a toggle-mode dictation auto-stops. 0 = never.
    @Published var silenceAutoStopSeconds: Double {
        didSet {
            UserDefaults.standard.set(silenceAutoStopSeconds, forKey: "silenceAutoStopSeconds")
        }
    }
    @Published var voiceFocusEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceFocusEnabled, forKey: "voiceFocusEnabled")
            controller.setVoiceFocusEnabled(voiceFocusEnabled)
        }
    }
    @Published var voiceActivityFilteringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                voiceActivityFilteringEnabled,
                forKey: "voiceActivityFilteringEnabled"
            )
        }
    }

    // Model
    @Published var modelReady = false
    @Published var modelStatus = "Speech model not verified"
    @Published private(set) var selectedSpeechModel: SpeechModelChoice
    @Published private(set) var modelSwitchInProgress = false

    // Permissions
    @Published var microphoneAuthorized = false
    @Published var accessibilityTrusted = false
    @Published private(set) var deliveryMode: DictationDeliveryMode {
        didSet { UserDefaults.standard.set(deliveryMode.rawValue, forKey: "dictationDeliveryMode") }
    }
    var automaticInsertionEnabled: Bool { deliveryMode.requiresAccessibility }
    @Published private(set) var shortcutMigrationNoticePending: Bool

    // Context
    @Published var activeProfile: AppProfile = .general
    @Published var targetAppName: String? = nil
    @Published private(set) var profileOverrideID: String? {
        didSet { UserDefaults.standard.set(profileOverrideID, forKey: "profileOverrideID") }
    }
    /// Opt-in for the post-insertion edit watch.
    @Published var learnFromEditsEnabled: Bool {
        didSet { UserDefaults.standard.set(learnFromEditsEnabled, forKey: "learnFromEditsEnabled") }
    }
    /// Transient confirmation that a correction was just learned, with the
    /// saved rule's identity so one tap can undo it.
    @Published var vocabularyToast: VocabularyToast? = nil
    private var vocabularyToastToken: UUID?

    // History
    @Published var historyEntries: [HistoryEntry] = []

    // Activation
    @Published var activationMode: ActivationMode {
        didSet { UserDefaults.standard.set(activationMode.rawValue, forKey: "activationMode") }
    }
    @Published var activationTrigger: ActivationTrigger {
        didSet {
            UserDefaults.standard.set(activationTrigger.rawValue, forKey: "activationTrigger")
            applyMouseTrigger()
        }
    }
    @Published var mouseButton: Int {
        didSet {
            UserDefaults.standard.set(mouseButton, forKey: "mouseButton")
            applyMouseTrigger()
        }
    }

    var effectiveProfile: AppProfile {
        if let id = profileOverrideID,
            let profile = AppProfile.builtIn.first(where: { $0.id == id })
        {
            return profile
        }
        return activeProfile
    }

    var availableProfiles: [AppProfile] { AppProfile.builtIn }

    /// Profile and output policy must remain stable for the entire capture and
    /// delivery transaction.
    var canChangeTranscriptPolicy: Bool {
        guard !isMeetingRecording, !canRetryFailedDictation else { return false }
        switch pipelineState {
        case .idle, .ready, .done, .failed:
            return true
        case .preparing, .recording, .transcribing, .processing, .inserting:
            return false
        }
    }

    // Output
    @Published var lastRaw = ""
    @Published var lastFinal = ""
    @Published var statusMessage: String? = nil
    @Published var errorMessage: String? = nil
    @Published private(set) var pendingReinsertInspection: ReinsertInspectionNotice? = nil
    @Published private(set) var canRetryFailedDictation = false
    @Published private(set) var failedRetryIsMeeting = false
    @Published private(set) var pipelineIsMeeting = false
    @Published var wordsThisSession = 0
    @Published var statsWordsTotal = 0
    @Published var statsDictationsTotal = 0
    @Published var statsAverageWPM = 0

    func refreshStats() {
        statsWordsTotal = StatsStore.shared.wordsTotal
        statsDictationsTotal = StatsStore.shared.dictationsTotal
        statsAverageWPM = StatsStore.shared.averageWPM
    }

    func resetStats() {
        StatsStore.shared.reset()
        refreshStats()
        statusMessage = "Local usage totals reset."
    }

    // Preferences (persisted)
    @Published var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published var spokenPunctuation: Bool {
        didSet { UserDefaults.standard.set(spokenPunctuation, forKey: "spokenPunctuation") }
    }
    @Published var launchAtLogin: Bool {
        didSet { LaunchAtLogin.set(launchAtLogin, state: self) }
    }
    @Published var llmCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(llmCleanupEnabled, forKey: "llmCleanupEnabled") }
    }

    // Additive features (opt-in — the app stays simple unless you turn these on)
    @Published var translationTarget: LLMTranslator.TargetLanguage {
        didSet {
            UserDefaults.standard.set(translationTarget.rawValue, forKey: "translationTarget")
        }
    }
    @Published var meetingNotesEnabled: Bool {
        didSet { UserDefaults.standard.set(meetingNotesEnabled, forKey: "meetingNotesEnabled") }
    }
    @Published var isMeetingRecording = false
    @Published var meetings: [Meeting] = []

    /// Used only by the deterministic, offscreen marketing renderer. It avoids
    /// hotkeys, permissions, model work, overlays, and all user data while still
    /// rendering the production SwiftUI views.
    let isMarketingPreview: Bool

    func refreshMeetings() {
        meetings = MeetingStore.shared.all()
    }

    lazy var controller = DictationController(state: self)
    let overlay = OverlayController()

    init(
        marketingPreview: Bool = false,
        marketingProfileOverrideID: String? = nil
    ) {
        isMarketingPreview = marketingPreview
        let defaults = UserDefaults.standard
        _deliveryMode = Published(
            initialValue: marketingPreview
                ? .inApp
                : DictationDeliveryMode(
                    storedPreference: defaults.string(forKey: "dictationDeliveryMode")))
        // Initialize underlying Published storage directly: assigning to an observed
        // property in init is treated as a use of `self` before full initialization.
        let requestedProfileOverrideID =
            marketingPreview
            ? marketingProfileOverrideID
            : defaults.string(forKey: "profileOverrideID")
        let savedProfileOverrideID = requestedProfileOverrideID.flatMap { requestedID in
            AppProfile.builtIn.contains(where: { $0.id == requestedID }) ? requestedID : nil
        }
        if requestedProfileOverrideID != nil, savedProfileOverrideID == nil, !marketingPreview {
            defaults.removeObject(forKey: "profileOverrideID")
        }
        _cleanupEnabled = Published(
            initialValue: marketingPreview
                ? true
                : defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        )
        _spokenPunctuation = Published(
            initialValue: marketingPreview
                ? true : defaults.object(forKey: "spokenPunctuation") as? Bool ?? true)
        _profileOverrideID = Published(initialValue: savedProfileOverrideID)
        _learnFromEditsEnabled = Published(
            initialValue: marketingPreview
                ? false
                : defaults.object(forKey: "learnFromEditsEnabled") as? Bool ?? false
        )
        _shortcutMigrationNoticePending = Published(
            initialValue: marketingPreview
                ? false
                : DictationShortcutPreference.migrationNoticeIsPending
        )
        // Toggle is the default: press the shortcut to start, then again to stop.
        let mode =
            marketingPreview
            ? ActivationMode.toggle.rawValue
            : defaults.string(forKey: "activationMode") ?? ActivationMode.toggle.rawValue
        _activationMode = Published(initialValue: ActivationMode(rawValue: mode) ?? .toggle)
        let trigger =
            marketingPreview
            ? ActivationTrigger.keyboard.rawValue
            : defaults.string(forKey: "activationTrigger") ?? ActivationTrigger.keyboard.rawValue
        _activationTrigger = Published(
            initialValue: ActivationTrigger(rawValue: trigger) ?? .keyboard)
        _mouseButton = Published(
            initialValue: marketingPreview ? 2 : defaults.object(forKey: "mouseButton") as? Int ?? 2
        )
        _launchAtLogin = Published(initialValue: marketingPreview ? false : LaunchAtLogin.isEnabled)
        _llmCleanupEnabled = Published(
            initialValue: marketingPreview
                ? true
                : defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? false
        )
        let target =
            marketingPreview
            ? LLMTranslator.TargetLanguage.off.rawValue
            : defaults.string(forKey: "translationTarget")
                ?? LLMTranslator.TargetLanguage.off.rawValue
        _translationTarget = Published(
            initialValue: LLMTranslator.TargetLanguage(rawValue: target) ?? .off
        )
        _meetingNotesEnabled = Published(
            initialValue: marketingPreview
                ? false : defaults.object(forKey: "meetingNotesEnabled") as? Bool ?? false)
        let barMode =
            marketingPreview
            ? BarVisibility.always.rawValue
            : defaults.string(forKey: "barVisibility") ?? BarVisibility.always.rawValue
        _barVisibility = Published(initialValue: BarVisibility(rawValue: barMode) ?? .always)
        _autoCopyEnabled = Published(
            initialValue: marketingPreview
                ? false : defaults.object(forKey: "autoCopyEnabled") as? Bool ?? false)
        _silenceAutoStopSeconds = Published(
            initialValue: marketingPreview
                ? 0 : defaults.object(forKey: "silenceAutoStopSeconds") as? Double ?? 0)
        _voiceFocusEnabled = Published(
            initialValue: marketingPreview
                ? false
                : VoiceFocusPreferencePolicy.isEnabled(
                    storedPreference: defaults.object(
                        forKey: "voiceFocusEnabled"
                    ) as? Bool
                )
        )
        _voiceActivityFilteringEnabled = Published(
            initialValue: marketingPreview
                ? true : defaults.object(forKey: "voiceActivityFilteringEnabled") as? Bool ?? true
        )
        let savedSpeechModel =
            marketingPreview ? nil : defaults.string(forKey: "selectedSpeechModel")
        _selectedSpeechModel = Published(
            initialValue: SpeechModelChoice(rawValue: savedSpeechModel ?? "")
                ?? .multilingual
        )

        if marketingPreview {
            modelReady = true
            modelStatus = "Ready"
            microphoneAuthorized = true
            accessibilityTrusted = true
            pipelineState = .ready
            activeProfile = .general
            return
        }

        let didMigrateShortcut = DictationShortcutPreference.migrateLegacyDefaultIfNeeded()
        let pendingNoticeAfterLaunch =
            DictationShortcutMigrationNoticePolicy.pendingAfterLaunch(
                persistedPending: shortcutMigrationNoticePending,
                migrationDidOccur: didMigrateShortcut
            )
        if pendingNoticeAfterLaunch != shortcutMigrationNoticePending {
            DictationShortcutPreference.setMigrationNoticePending(pendingNoticeAfterLaunch)
            shortcutMigrationNoticePending = pendingNoticeAfterLaunch
        }
        registerHotkeys()
        observeWorkspace()
        observeHomeWindowRequests()
        refreshPermissions()
        captureCurrentFrontmost()
        refreshHistory()
        refreshStats()
        refreshMeetings()
        overlay.attach(state: self)
        startWatchdog()
        applyMouseTrigger()
        Task { await prepareModel() }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            showOnboardingIfNeeded()
        }
    }

    var menuBarIcon: String {
        switch pipelineState {
        case .idle: return "mic"
        case .preparing: return "arrow.down.circle"
        case .ready: return "mic"
        case .recording: return "mic.fill"
        case .transcribing, .processing, .inserting: return "ellipsis"
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var canDictate: Bool {
        modelReady
            && deliveryMode.canRecord(
                microphoneAuthorized: microphoneAuthorized,
                accessibilityTrusted: accessibilityTrusted)
    }

    var canStartDictation: Bool {
        canDictate
    }

    var primaryDictationAction: PrimaryDictationAction {
        if pipelineState == .recording { return .finish }
        if pipelineState == .preparing { return .preparingModel }
        if [.transcribing, .processing, .inserting].contains(pipelineState) {
            return .working
        }
        if !modelReady {
            if modelSwitchInProgress || pipelineState == .preparing || errorMessage == nil {
                return .preparingModel
            }
            return .retryModel
        }
        if canRetryFailedDictation { return .retry }
        if !microphoneAuthorized { return .requestMicrophone }
        if automaticInsertionEnabled && !accessibilityTrusted { return .requestAccessibility }
        return .start
    }

    var systemInputName: String {
        if isMarketingPreview { return "Mac microphone" }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "No input device detected"
    }

    var canChangeSpeechModel: Bool {
        guard !modelSwitchInProgress, !canRetryFailedDictation else { return false }
        switch pipelineState {
        case .idle, .ready, .done, .failed:
            return true
        case .preparing, .recording, .transcribing, .processing, .inserting:
            return false
        }
    }

    var activeSpeechModelShortName: String {
        controller.modelShortName
    }

    var activationHint: String {
        if isMarketingPreview { return DictationShortcutPreference.currentDefault.description }
        switch activationTrigger {
        case .keyboard:
            return KeyboardShortcuts.getShortcut(for: .holdToTalk)?.description
                ?? "Keyboard shortcut"
        case .mouse:
            switch mouseButton {
            case 2: return "Middle mouse button"
            case 3: return "Mouse back button"
            case 4: return "Mouse forward button"
            default: return "Configured mouse button"
            }
        }
    }

    var shouldShowShortcutMigrationNotice: Bool {
        DictationShortcutMigrationNoticePolicy.shouldPresent(
            isPending: shortcutMigrationNoticePending,
            modelIsReady: modelReady
        )
    }

    func dismissShortcutMigrationNotice() {
        DictationShortcutPreference.setMigrationNoticePending(false)
        shortcutMigrationNoticePending = false
    }

    func useBareFunctionShortcut() {
        DictationShortcutPreference.useBareFunctionShortcut()
        dismissShortcutMigrationNotice()
        statusMessage =
            "Fn is now the dictation shortcut. Close other dictation apps if they also use Fn."
    }

    func useRecommendedShortcut() {
        DictationShortcutPreference.useRecommendedShortcut()
        dismissShortcutMigrationNotice()
        statusMessage = "Control-Shift-Space is now the dictation shortcut."
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .holdToTalk) { [weak self] in
            self?.controller.hotKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .holdToTalk) { [weak self] in
            self?.controller.hotKeyUp()
        }
    }

    private func applyMouseTrigger() {
        let trigger = MouseTrigger.shared
        trigger.buttonNumber = mouseButton
        trigger.isEnabled = activationTrigger == .mouse
        trigger.onTrigger = { [weak self] in
            // Mouse activation is always toggle semantics.
            self?.controller.toggleFromBar()
        }
        trigger.apply()
    }

    func resetBarPosition() {
        overlay.resetPosition()
    }

    // MARK: - Workspace tracking

    private func observeHomeWindowRequests() {
        NotificationCenter.default.addObserver(
            forName: .lockedInFlowShowHome,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showHomeWindow()
            }
        }
    }

    private func observeWorkspace() {
        // NSWorkspace posts its notifications only through this center. The
        // default center never receives app-activation changes, which would
        // leave the insertion target frozen at whichever app was frontmost
        // when LockedIn Flow launched.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor in
                guard let self, self.automaticInsertionEnabled else { return }
                let isSelf = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
                FrontmostTracker.shared.noteActivation(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName,
                    isSelf: isSelf
                )
                self.updateContext()
            }
        }
    }

    private func captureCurrentFrontmost() {
        guard automaticInsertionEnabled,
            let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        FrontmostTracker.shared.noteActivation(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            isSelf: false
        )
        updateContext()
    }

    func updateContext() {
        guard automaticInsertionEnabled else {
            targetAppName = nil
            activeProfile = .general
            return
        }
        targetAppName = FrontmostTracker.shared.targetAppName()
        activeProfile = AppProfile.profile(forBundleID: FrontmostTracker.shared.targetBundleID())
    }

    // MARK: - Watchdog

    private var stateEnteredAt = Date()

    /// How long transcribe→cleanup→insert may legitimately take for the current
    /// dictation. Set by the controller from the captured audio length — long
    /// dictations get a long leash, short ones recover fast. Never below 60 s.
    var processingBudgetSeconds: TimeInterval = 60

    /// If the pipeline ever wedges (hotkey death, stalled inference, a target app
    /// holding an AX call), the app must recover itself — "always works" means
    /// never needing a manual kill. Every 15 s, any state stuck too long is reset.
    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPipelineHealth()
            }
        }
    }

    private func checkPipelineHealth() {
        if pipelineState != lastWatchedState {
            lastWatchedState = pipelineState
            stateEnteredAt = Date()
            return
        }
        let stuckFor = Date().timeIntervalSince(stateEnteredAt)
        switch pipelineState {
        case .transcribing, .processing, .inserting:
            if stuckFor > processingBudgetSeconds {
                FlowLog.error(
                    "watchdog: processing exceeded budget \(self.processingBudgetSeconds)s — cancelled"
                )
                controller.recoverFromProcessingTimeout()
            }
        case .recording:
            let recordingLimit: TimeInterval = isMeetingRecording ? 3_660 : 660
            if stuckFor > recordingLimit {
                FlowLog.error("watchdog: recording exceeded \(recordingLimit)s — cancelled")
                controller.cancel()
                pipelineState = .ready
            }
        default:
            break
        }
    }

    private var lastWatchedState: PipelineState = .idle

    // MARK: - Permissions

    func refreshPermissions() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityTrusted = TextInserter.isTrusted(prompt: false)
    }

    func requestMicrophoneAccess() {
        Task {
            _ = await AudioCaptureManager.microphoneAuthorized()
            refreshPermissions()
        }
    }

    func requestAccessibilityAccess() {
        guard !isMarketingPreview, canChangeTranscriptPolicy else { return }
        let bundle = Bundle.main
        guard
            AccessibilityRequestIdentity.permitsPrompt(
                bundleIdentifier: bundle.bundleIdentifier,
                bundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                executableName: bundle.object(forInfoDictionaryKey: "CFBundleExecutable")
                    as? String,
                runningExecutableName: bundle.executableURL?.lastPathComponent,
                isApplicationBundle: bundle.bundleURL.pathExtension == "app"
            )
        else {
            errorMessage =
                "Automatic insertion is available only from the packaged LockedIn Flow app. This build will not request Accessibility access. In-app transcription remains available."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable automatic typing in other apps?"
        alert.informativeText =
            "This is optional. Transcribe in LockedIn Flow and use Copy without Accessibility access.\n\nAutomatic typing uses macOS Accessibility permission to inspect the focused editor and insert text. macOS describes this broad permission as control of your computer; it is not limited to typing. Grant it only if you trust LockedIn Flow and your organization permits it.\n\nThe next macOS request must identify LockedIn Flow. Decline a request with any other name."
        alert.addButton(withTitle: "Continue to macOS permission")
        alert.addButton(withTitle: "Keep in-app transcription")
        alert.window.title = "LockedIn Flow"
        guard alert.runModal() == .alertFirstButtonReturn, canChangeTranscriptPolicy else { return }
        deliveryMode = .automaticInsertion
        _ = TextInserter.isTrusted(prompt: true)
        refreshPermissions()
        updateContext()
    }

    func useInAppTranscription() {
        guard canChangeTranscriptPolicy else { return }
        deliveryMode = .inApp
        updateContext()
        statusMessage = "Transcripts stay in LockedIn Flow until you choose Copy."
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )!)
    }

    func openSoundInputSettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension?input",
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        ]
        for destination in destinations {
            if let url = URL(string: destination), NSWorkspace.shared.open(url) {
                return
            }
        }
        errorMessage = "Sound settings could not be opened. Open System Settings → Sound → Input."
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    // MARK: - Model

    func prepareModel() async {
        guard !modelReady, !modelSwitchInProgress else { return }
        modelSwitchInProgress = true
        defer { modelSwitchInProgress = false }
        if [.idle, .ready, .failed].contains(pipelineState) {
            pipelineState = .preparing
        }
        errorMessage = nil
        modelStatus = "Verifying provisioned speech model…"
        do {
            try await controller.prepareSTT(for: selectedSpeechModel)
            modelReady = true
            modelStatus = controller.modelDisplayName
            if pipelineState == .preparing { pipelineState = .ready }
            errorMessage = nil
            statusMessage = nil
            Task { await controller.prewarmVoiceActivityDetection() }
        } catch {
            if selectedSpeechModel != .multilingual {
                FlowLog.info(
                    "selected speech model unavailable; falling back to multilingual code=\(errorCode: error)"
                )
                do {
                    try await controller.prepareSTT(for: .multilingual)
                    selectedSpeechModel = .multilingual
                    UserDefaults.standard.set(
                        SpeechModelChoice.multilingual.rawValue,
                        forKey: "selectedSpeechModel"
                    )
                    modelReady = true
                    modelStatus = controller.modelDisplayName
                    statusMessage = "English Precision was unavailable. Multilingual is ready."
                    if pipelineState == .preparing { pipelineState = .ready }
                    Task { await controller.prewarmVoiceActivityDetection() }
                    return
                } catch {
                    FlowLog.error("fallback speech model failed code=\(errorCode: error)")
                }
            }
            modelStatus = "Provisioned model unavailable"
            errorMessage = error.localizedDescription
            if pipelineState == .preparing { pipelineState = .failed }
        }
    }

    func selectSpeechModel(_ choice: SpeechModelChoice) async {
        guard choice != selectedSpeechModel, canChangeSpeechModel else { return }

        let priorStatus = modelStatus
        let priorReady = modelReady
        modelSwitchInProgress = true
        modelReady = false
        pipelineState = .preparing
        modelStatus = "Verifying \(choice.displayName)…"
        errorMessage = nil

        do {
            try await controller.prepareSTT(for: choice)
            selectedSpeechModel = choice
            UserDefaults.standard.set(choice.rawValue, forKey: "selectedSpeechModel")
            modelReady = true
            modelStatus = controller.modelDisplayName
            pipelineState = .ready
            statusMessage = "\(choice.displayName) is ready."
        } catch {
            modelReady = priorReady
            modelStatus = priorStatus
            pipelineState = priorReady ? .ready : .failed
            errorMessage =
                "\(choice.displayName) could not be verified. Your current model is still active. \(error.localizedDescription)"
            FlowLog.error("speech model switch failed code=\(errorCode: error)")
        }
        modelSwitchInProgress = false
    }

    // MARK: - User actions

    func copyLastTranscript() {
        guard !lastFinal.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(lastFinal, forType: .string)
        statusMessage = "Copied to clipboard"
    }

    func reinsertLastTranscript() {
        controller.reinsertLast()
    }

    func acknowledgeReinsertInspection(_ notice: ReinsertInspectionNotice) {
        controller.acknowledgeReinsertInspection(notice)
    }

    func presentReinsertInspection(_ notice: ReinsertInspectionNotice) {
        pendingReinsertInspection = notice
        statusMessage = nil
        errorMessage = notice.message
    }

    func clearReinsertInspection(_ notice: ReinsertInspectionNotice) {
        guard pendingReinsertInspection == notice else { return }
        pendingReinsertInspection = nil
        if errorMessage == notice.message {
            errorMessage = nil
        }
    }

    func cancelDictation() {
        controller.cancel()
    }

    func retryFailedDictation() {
        controller.retryFailedDictation()
    }

    func discardFailedDictation() {
        controller.discardFailedDictation()
    }

    func performPrimaryDictationAction() {
        switch primaryDictationAction {
        case .start, .finish:
            controller.toggleFromBar()
        case .retry:
            retryFailedDictation()
        case .retryModel:
            Task { await prepareModel() }
        case .requestMicrophone:
            requestMicrophoneAccess()
        case .requestAccessibility:
            requestAccessibilityAccess()
        case .preparingModel, .working:
            break
        }
    }

    // MARK: - Learned corrections from edits

    /// Announces a just-learned correction and keeps an undo handle live for a
    /// few seconds. The message carries only the vocabulary terms themselves.
    func showVocabularyToast(spoken: String, written: String, ruleID: UUID) {
        vocabularyToast = VocabularyToast(
            message: "Learned \u{201C}\(written)\u{201D} from your edit",
            ruleID: ruleID
        )
        let token = UUID()
        vocabularyToastToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.vocabularyToastToken == token else { return }
            self.vocabularyToast = nil
        }
    }

    /// Removes the rule the visible toast refers to. Learned corrections also
    /// remain individually deletable later in Settings → Vocabulary.
    func undoLearnedCorrection() {
        guard let toast = vocabularyToast else { return }
        do {
            try VocabularyStore.removeRule(id: toast.ruleID)
            controller.reloadVocabulary()
            vocabularyToastToken = nil
            vocabularyToast = nil
            statusMessage = "Removed the learned correction."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Profiles

    func setProfileOverrideID(_ id: String?) {
        guard id == nil || availableProfiles.contains(where: { $0.id == id }) else {
            profileOverrideID = nil
            errorMessage = "That profile is not available in this build."
            return
        }
        profileOverrideID = id
    }

    /// Controller-only bridge for publishing session retry availability to UI.
    func updateFailedDictationRetryAvailability(
        _ isAvailable: Bool,
        isMeeting: Bool = false
    ) {
        canRetryFailedDictation = isAvailable
        failedRetryIsMeeting = isAvailable && isMeeting
    }

    /// Controller-only bridge that lets the UI use truthful meeting-specific
    /// labels through recording, transcription, completion, and failure.
    func updatePipelineMeetingState(_ isMeeting: Bool) {
        pipelineIsMeeting = isMeeting
    }

    // MARK: - History & windows

    func refreshHistory() {
        historyEntries = HistoryStore.shared.all()
    }

    func deleteHistoryEntry(_ id: UUID) {
        if let entry = HistoryStore.shared.all().first(where: { $0.id == id }) {
            RecoveryStore.shared.deleteMatching(raw: entry.raw, final: entry.final)
        }
        HistoryStore.shared.delete(id: id)
        refreshHistory()
    }

    func deleteAllHistory() {
        HistoryStore.shared.deleteAll()
        RecoveryStore.shared.clear()
        refreshHistory()
    }

    func setHistoryRetention(_ retention: RetentionPolicy) {
        HistoryStore.shared.retention = retention
        RecoveryStore.shared.applyRetention(retention)
        refreshHistory()
    }

    func reinsert(
        _ text: String,
        sourceID: UUID? = nil,
        completion: @escaping (Result<ReinsertSuccess, Error>) -> Void = { _ in }
    ) {
        controller.reinsert(text, sourceID: sourceID, completion: completion)
    }

    func showHistoryWindow() {
        WindowOpener.shared.showHistory(state: self)
    }

    func showHomeWindow() {
        WindowOpener.shared.showHome(state: self)
    }

    func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboardingCompleted") else { return }
        WindowOpener.shared.showOnboarding(state: self)
    }

    var firstDictationReadiness: FirstDictationReadiness {
        FirstDictationReadiness(
            modelReady: modelReady,
            modelChecking: modelSwitchInProgress || pipelineState == .preparing,
            microphoneAuthorized: microphoneAuthorized,
            accessibilityTrusted: accessibilityTrusted,
            deliveryMode: deliveryMode
        )
    }

    func completeOnboarding() {
        guard firstDictationReadiness.canFinish, !isMarketingPreview else { return }
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        WindowOpener.shared.closeOnboarding()
        showHomeWindow()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
