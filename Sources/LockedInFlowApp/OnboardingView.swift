import SwiftUI
import VoiceCore

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var page: Int
    @State private var permissionTimer: Timer?

    init(initialPage: Int = 0) {
        _page = State(initialValue: min(2, max(0, initialPage)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Setup step", selection: $page) {
                Text("Welcome").tag(0)
                Text("Permissions").tag(1)
                Text("Speech model").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(16)

            Group {
                switch page {
                case 1: permissionsPage
                case 2: modelPage
                default: welcomePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                if page < 2 {
                    Button("Continue") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    completionAction
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !state.isMarketingPreview { startPermissionPolling() }
        }
        .onDisappear { permissionTimer?.invalidate() }
    }

    @ViewBuilder
    private var completionAction: some View {
        switch state.firstDictationReadiness.nextAction {
        case .waitForModel:
            Button("Checking models…") {}
                .disabled(true)
        case .setUpModel:
            Button("Set up speech models") {
                WindowOpener.shared.showModelSetup(state: state)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Opens local setup instructions; does not download or record")
        case .reviewPermissions:
            Button("Review permissions") { page = 1 }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Returns to the microphone and text insertion permissions")
        case .openDictation:
            Button("Open LockedIn Flow") { state.completeOnboarding() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Completes setup and opens the app without starting a recording")
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color(nsColor: .systemTeal))
            Text("Private voice input that runs\nentirely on your Mac.")
                .font(.title3)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio never leaves this device", systemImage: "lock.shield")
                Label("Uses only pre-provisioned, verified models", systemImage: "wifi.slash")
                Label(
                    "No accounts, analytics upload, or telemetry",
                    systemImage: "eye.slash"
                )
                Label(
                    "Dictation history stays in memory until quit by default",
                    systemImage: "memorychip")
            }
            .font(.callout)
            .foregroundStyle(.primary)
            Spacer()
        }
        .padding()
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Microphone access for local transcription.")
                .font(.title3)
            permissionRow(
                title: "Microphone",
                detail: "Captures your voice for on-device transcription.",
                granted: state.microphoneAuthorized,
                action: { state.requestMicrophoneAccess() }
            )
            Text(
                "Your transcript appears in LockedIn Flow. Use Copy and paste it yourself. No Accessibility access or control of other apps is required."
            )
            .font(.callout)
            .foregroundStyle(.primary)
            Divider()
            Text("Automatic typing is optional")
                .font(.headline)
            Text(
                "To type directly into other apps, you can opt in later in Settings → Permissions. macOS requires broad Accessibility access for that feature. It is off by default."
            )
            .font(.caption)
            if state.automaticInsertionEnabled {
                Text(
                    state.accessibilityTrusted
                        ? "Automatic typing is enabled."
                        : "Automatic typing is selected but its permission is missing.")
                HStack {
                    Button("Use in-app transcription") { state.useInAppTranscription() }
                    if !state.accessibilityTrusted {
                        Button("Review automatic typing…") { state.requestAccessibilityAccess() }
                    }
                }
                .disabled(!state.canChangeTranscriptPolicy)
            }
            Spacer()
        }
        .padding()
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
                )
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .accessibilityLabel("Allow \(title) access")
            } else {
                Text("Allowed")
                    .font(.caption)
            }
        }
    }

    private var modelPage: some View {
        VStack(spacing: 16) {
            Spacer()
            if state.modelReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text("Speech model ready.")
                    .font(.title3)
                Text(state.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text(
                    state.firstDictationReadiness.nextAction == .reviewPermissions
                        ? "Your model is ready. Review the remaining permission for your selected dictation mode."
                        : activationInstructions
                )
                .multilineTextAlignment(.center)
                .font(.callout)
            } else {
                if state.modelSwitchInProgress {
                    ProgressView()
                        .controlSize(.large)
                    Text(state.modelStatus)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text("Checking the provisioned model against the reviewed manifest…")
                        .font(.caption)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text(state.errorMessage ?? state.modelStatus)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(
                        "Open the setup guide below for source-build or managed-Mac instructions. Nothing is downloaded automatically."
                    )
                    .font(.caption)
                    .foregroundStyle(.primary)
                }
            }
            Spacer()
        }
        .padding()
    }

    private var activationInstructions: String {
        if !state.automaticInsertionEnabled {
            return
                "Use \(state.activationHint) to dictate. Your transcript appears in LockedIn Flow; choose Copy when you want to use it elsewhere. No Accessibility access is needed."
        }
        if state.activationTrigger == .keyboard, state.activationMode == .hold {
            return
                "Hold \(state.activationHint) anywhere while you speak, then release — text lands at your cursor."
        }
        return
            "Use \(state.activationHint) anywhere to start, speak, then use it again to stop — text lands at your cursor."
    }

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in state.refreshPermissions() }
        }
    }
}
