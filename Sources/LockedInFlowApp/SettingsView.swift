import KeyboardShortcuts
import SpeechEngine
import SwiftUI
import TextIntelligence
import VoiceCore

struct SettingsView: View {
    enum Tab: Hashable {
        case general
        case vocabulary
        case snippets
        case model
        case permissions
        case about
    }

    @EnvironmentObject var state: AppState
    @State private var selectedTab: Tab
    @State private var showingAcknowledgments = false
    @State private var showingBareFunctionConfirmation = false
    @State private var showingResetStatsConfirmation = false

    init(initialTab: Tab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)
            vocabularyTab
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
                .tag(Tab.vocabulary)
            snippetsTab
                .tabItem { Label("Snippets", systemImage: "text.append") }
                .tag(Tab.snippets)
            modelTab
                .tabItem { Label("Speech Model", systemImage: "waveform") }
                .tag(Tab.model)
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Tab.permissions)
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 480, height: 340)
        .padding()
        .alert("Use Fn anyway?", isPresented: $showingBareFunctionConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Use Fn Anyway", role: .destructive) {
                state.useBareFunctionShortcut()
            }
        } message: {
            Text(
                "Another dictation app may also monitor bare Fn. If more than one is running, one press can start both and move the target field. Use Fn only when other dictation apps are closed or configured with a different shortcut."
            )
        }
        .confirmationDialog(
            "Reset local usage totals?",
            isPresented: $showingResetStatsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Usage Totals", role: .destructive) {
                state.resetStats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes local word, dictation, speaking-time, and first-use totals.")
        }
    }

    private var vocabularyTab: some View {
        VocabularyView()
            .environmentObject(state)
            .disabled(!state.canChangeTranscriptPolicy)
    }

    private var snippetsTab: some View {
        SnippetsView()
            .environmentObject(state)
            .disabled(!state.canChangeTranscriptPolicy)
    }

    private var generalTab: some View {
        Form {
            Section("Activation") {
                Picker("Trigger with", selection: $state.activationTrigger) {
                    ForEach(ActivationTrigger.allCases) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                if state.activationTrigger == .keyboard {
                    KeyboardShortcuts.Recorder("Shortcut:", name: .holdToTalk)
                    Text(
                        "Control-Shift-Space is recommended. Bare Fn can be claimed by another dictation app at the same time, which may interrupt the shortcut or microphone."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Use Control-Shift-Space") {
                            state.useRecommendedShortcut()
                        }
                        .controlSize(.small)
                        Spacer()
                        Button("Use Fn Anyway…") {
                            showingBareFunctionConfirmation = true
                        }
                        .controlSize(.small)
                    }
                } else {
                    Picker("Mouse button", selection: $state.mouseButton) {
                        Text("Middle (wheel)").tag(2)
                        Text("Back (button 4)").tag(3)
                        Text("Forward (button 5)").tag(4)
                    }
                    Text(
                        "The click still passes through to your apps — dictation toggles on top of it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Picker("Mode", selection: $state.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if state.activationMode == .toggle {
                    Picker("Auto-stop after silence", selection: $state.silenceAutoStopSeconds) {
                        Text("2 seconds").tag(2.0)
                        Text("3.5 seconds").tag(3.5)
                        Text("5 seconds").tag(5.0)
                        Text("Never").tag(0.0)
                    }
                }
                Text(
                    state.activationMode == .hold
                        ? "Hold the key, speak, release. Your transcript follows the output mode in Permissions."
                        : "Press once to start; press again — or pause — to stop. Stops automatically after the silence window above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Audio") {
                HStack {
                    Label(state.systemInputName, systemImage: "mic")
                        .lineLimit(1)
                        .help(state.systemInputName)
                    Spacer()
                    Button("Sound Input Settings…") {
                        state.openSoundInputSettings()
                    }
                    .controlSize(.small)
                }
                Text(
                    "LockedIn Flow follows the input selected in macOS. Change it in Sound settings before starting a recording."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Voice Focus", isOn: $state.voiceFocusEnabled)
                    .disabled(state.pipelineState == .recording)
                Text(
                    state.voiceFocusEnabled
                        ? "Uses Apple’s system voice processing to reduce steady background noise. Turn it off if an external microphone is unreliable."
                        : "Standard capture is active. Voice Focus remains optional for compatible microphone and output combinations."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle(
                    "Ignore non-speech at the edges",
                    isOn: $state.voiceActivityFilteringEnabled
                )
                .disabled(!state.canChangeTranscriptPolicy)
                Text(
                    "On-device voice detection can trim leading and trailing non-speech. If the detector is unavailable or reports no speech in a recording long enough for direct transcription, LockedIn Flow uses the full recording."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Profile") {
                Picker(
                    "Active profile",
                    selection: Binding(
                        get: { state.profileOverrideID },
                        set: { state.setProfileOverrideID($0) }
                    )
                ) {
                    Text(
                        state.automaticInsertionEnabled
                            ? "Auto (follows frontmost app)" : "General (in-app transcription)"
                    )
                    .tag(String?.none)
                    ForEach(state.availableProfiles) { profile in
                        Text(profile.name).tag(String?.some(profile.id))
                    }
                }
                .disabled(!state.canChangeTranscriptPolicy)
            }
            Section("Floating Bar") {
                Picker("Visibility", selection: $state.barVisibility) {
                    ForEach(BarVisibility.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                HStack {
                    Text("Drag the bar anywhere — it stays where you leave it, across restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Position") { state.resetBarPosition() }
                        .controlSize(.small)
                }
            }
            Section("Clipboard") {
                Toggle(
                    "Keep automatically inserted text on the clipboard",
                    isOn: $state.autoCopyEnabled
                )
                .disabled(!state.canChangeTranscriptPolicy || !state.automaticInsertionEnabled)
                Text(
                    "Off by default and used only with automatic typing. In-app transcription never automatically changes the clipboard. Some destination apps require a temporary verified paste; LockedIn Flow restores the prior clipboard only while it still owns that transaction."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts", isOn: $state.cleanupEnabled)
                    .disabled(!state.canChangeTranscriptPolicy)
                Toggle(
                    "Interpret spoken punctuation (“comma”, “new paragraph”…)",
                    isOn: $state.spokenPunctuation
                )
                .disabled(!state.cleanupEnabled || !state.canChangeTranscriptPolicy)
                Toggle("LLM cleanup (local)", isOn: $state.llmCleanupEnabled)
                    .disabled(
                        !state.cleanupEnabled
                            || !LLMCleaner.isLLMAvailable
                            || !state.canChangeTranscriptPolicy
                    )
                LabeledContent("LLM provider", value: LLMCleaner.availabilityDescription)
                Text(
                    "Local rules remove fillers like “um,” “uh,” and “ah,” then repair punctuation, capitalization, common spelling, and formatting. On supported Macs, Apple Intelligence adds contextual grammar and spelling cleanup with meaning-preservation checks and instant rules fallback."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Features") {
                Text("Off by default — the app stays simple until you turn these on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Translate output to", selection: $state.translationTarget) {
                    ForEach(LLMTranslator.TargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(
                    !LLMTranslator.isAvailable
                        || !state.canChangeTranscriptPolicy
                )
                if state.translationTarget != .off {
                    Text(
                        "Speak any supported language — text lands in \(state.translationTarget.displayName.components(separatedBy: " ").first ?? "English"). On-device, no cloud."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !LLMTranslator.isAvailable {
                    Text("Translation requires macOS 26 + Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Meeting notes (beta)", isOn: $state.meetingNotesEnabled)
                    .disabled(
                        !MeetingSummarizer().isAvailable
                            || !state.canChangeTranscriptPolicy
                    )
                if state.meetingNotesEnabled {
                    Text(
                        "Adds a meeting recorder: mic captures the room, and you get a summary, key points, and action items. Meeting transcripts and notes are encrypted on this Mac until you delete them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !MeetingSummarizer().isAvailable {
                    Text("Meeting notes require macOS 26 + Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Link(
                    "View source releases…",
                    destination: URL(
                        string:
                            "https://github.com/LockedinLabs-AI/lockedin-flow/releases"
                    )!
                )
                Text("LockedIn Flow builds do not contact an automatic update service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modelTab: some View {
        Form {
            Section("Speech Recognition") {
                Picker(
                    "Optimize for",
                    selection: Binding(
                        get: { state.selectedSpeechModel },
                        set: { choice in
                            Task { await state.selectSpeechModel(choice) }
                        }
                    )
                ) {
                    ForEach(SpeechModelChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .disabled(!state.canChangeSpeechModel)
                LabeledContent("Model", value: state.selectedSpeechModel.technicalName)
                LabeledContent("Languages", value: state.selectedSpeechModel.languageSummary)
                LabeledContent("Runtime", value: "Apple Neural Engine · CoreML")
                LabeledContent("Status", value: state.modelStatus)
                if state.modelSwitchInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                if !state.modelReady {
                    Button("Verify Provisioned Model") {
                        Task { await state.prepareModel() }
                    }
                    .disabled(state.modelSwitchInProgress)
                }
                Text(state.selectedSpeechModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "The app does not download models at runtime. It verifies a pre-provisioned model against the reviewed manifest, then runs fully on-device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        Form {
            Section("Required") {
                HStack {
                    Label(
                        "Microphone",
                        systemImage: state.microphoneAuthorized
                            ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .foregroundStyle(
                        state.microphoneAuthorized
                            ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                    Spacer()
                    Button("Open Settings") { state.openMicrophoneSettings() }
                }
            }
            Section("Optional automatic typing") {
                Text("In-app transcription and Copy work without Accessibility access.")
                Text(
                    "Automatic typing inspects the focused editor and inserts your transcript. macOS grants broad Accessibility access for this feature, not a typing-only permission. Enable it only if you trust this app and your organization allows it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Label(
                        state.automaticInsertionEnabled
                            ? "Automatic typing selected" : "Automatic typing off",
                        systemImage: !state.automaticInsertionEnabled
                            ? "lock.shield"
                            : state.accessibilityTrusted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(
                        !state.automaticInsertionEnabled
                            ? Color.primary
                            : state.accessibilityTrusted
                                ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                    Spacer()
                    if state.automaticInsertionEnabled {
                        Button("Use in-app transcription") { state.useInAppTranscription() }
                    }
                    if !state.automaticInsertionEnabled || !state.accessibilityTrusted {
                        Button("Review and enable…") { state.requestAccessibilityAccess() }
                    }
                }
                .disabled(!state.canChangeTranscriptPolicy)
                Text(
                    "Turning automatic typing off stops this feature; it does not revoke a macOS permission already granted. You can revoke access in System Settings → Privacy & Security → Accessibility."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text(
                    "LockedIn Flow never uploads microphone audio or transcripts. One failed recording can remain in memory for retry and is never written to disk. Dictation History/Recovery stays in memory until quit by default; you can choose encrypted persistent retention. Optional meeting transcripts, notes, and local usage totals are encrypted on this Mac. Text you insert is then governed by the destination app. No analytics upload, telemetry, or accounts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Reset local usage totals…") {
                    showingResetStatsConfirmation = true
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color(nsColor: .systemTeal))
            Text("LockedIn Flow")
                .font(.title2).bold()
            Text("On-device voice input with no cloud speech service.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(versionLabel) · \(state.wordsThisSession) words this session")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button("Acknowledgments & Licenses…") {
                showingAcknowledgments = true
            }
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingAcknowledgments) {
            AcknowledgmentsView()
        }
    }

    private var versionLabel: String {
        let bundle = Bundle.main
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let base = build.map { "v\(version) (\($0))" } ?? "v\(version)"
        let stage = bundle.object(forInfoDictionaryKey: "LockedInReleaseStage") as? String
        return stage == "release-candidate" ? "\(base) · release candidate" : base
    }
}

private struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Acknowledgments")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            GroupBox("Speech Model") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Parakeet TDT 0.6B v3 and Parakeet Unified EN 0.6B by NVIDIA, converted to Core ML by FluidInference, are used under CC BY 4.0."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Link(
                            "Multilingual model",
                            destination: SpeechModelChoice.multilingual.modelPageURL)
                        Text("·")
                        Link(
                            "English model",
                            destination: SpeechModelChoice.englishPrecision.modelPageURL)
                        Text("·")
                        Link(
                            "CC BY 4.0",
                            destination: URL(
                                string: "https://creativecommons.org/licenses/by/4.0/")!)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Open Source") {
                VStack(alignment: .leading, spacing: 7) {
                    dependencyLink(
                        "FluidAudio",
                        license: "Apache 2.0",
                        url: "https://github.com/FluidInference/FluidAudio"
                    )
                    dependencyLink(
                        "KeyboardShortcuts",
                        license: "MIT",
                        url: "https://github.com/sindresorhus/KeyboardShortcuts"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let licensesDirectory, FileManager.default.fileExists(atPath: licensesDirectory.path)
            {
                Button("Show Full License Texts…") {
                    NSWorkspace.shared.open(licensesDirectory)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var licensesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
    }

    private func dependencyLink(_ name: String, license: String, url: String) -> some View {
        HStack {
            Link(name, destination: URL(string: url)!)
            Spacer()
            Text(license)
                .foregroundStyle(.secondary)
        }
    }
}
