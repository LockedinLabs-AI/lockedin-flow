import AppKit
import SwiftUI
import VoiceCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            FlowBrand.background

            VStack(alignment: .leading, spacing: 12) {
                header
                if state.shouldShowShortcutMigrationNotice {
                    shortcutMigrationNotice
                }
                statusSection
                if !state.historyEntries.isEmpty {
                    lastDictationSection
                }
                feedback
                footer
            }
            .padding(13)
        }
        .frame(width: 332)
        .preferredColorScheme(.dark)
    }

    private var shortcutMigrationNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Shortcut changed to Control-Shift-Space", systemImage: "keyboard")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(FlowBrand.warning)
            Text(
                "Bare Fn can trigger another dictation app at the same time. Change it in Settings → General → Activation."
            )
            .font(.system(size: 9.5))
            .foregroundStyle(FlowBrand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                SettingsLink {
                    Text("Shortcut Settings")
                }
                .buttonStyle(FlowCompactButtonStyle())
                Spacer()
                Button("Got it") {
                    state.dismissShortcutMigrationNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(FlowBrand.secondaryText)
                .underline()
            }
        }
        .padding(10)
        .background(FlowBrand.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(FlowBrand.warning.opacity(0.25), lineWidth: 0.8)
        }
    }

    private var header: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    FlowBrandTitle(compact: true)
                    Text("Private dictation on this Mac")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(FlowBrand.tertiaryText)
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(FlowBrand.success)
                        .frame(width: 6, height: 6)
                    Text("MIT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowBrand.secondaryText)
                }
            }

            Button {
                state.performPrimaryDictationAction()
            } label: {
                HStack {
                    Image(systemName: primaryActionIcon)
                    Text(primaryActionLabel)
                    Spacer()
                    if state.primaryDictationAction == .start {
                        Text(state.activationHint)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    state.pipelineState == .recording
                        ? AnyShapeStyle(FlowBrand.danger)
                        : AnyShapeStyle(FlowBrand.controlStrong),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            state.pipelineState == .recording
                                ? FlowBrand.danger.opacity(0.65) : FlowBrand.lineStrong,
                            lineWidth: 0.8
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!state.primaryDictationAction.isEnabled)
            .help(primaryActionHint)
            .accessibilityHint(primaryActionHint)

            HStack(spacing: 8) {
                if state.meetingNotesEnabled {
                    Button {
                        state.controller.toggleMeeting()
                    } label: {
                        Label(
                            state.isMeetingRecording ? "Stop meeting" : "Meeting",
                            systemImage: state.isMeetingRecording
                                ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .buttonStyle(FlowCompactButtonStyle())
                    .foregroundStyle(
                        state.isMeetingRecording ? FlowBrand.danger : FlowBrand.secondaryText
                    )
                    .disabled(meetingActionDisabled)
                    .help(meetingActionHint)

                    Button {
                        WindowOpener.shared.showMeetings(state: state)
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .buttonStyle(FlowCompactButtonStyle())
                    .foregroundStyle(FlowBrand.secondaryText)
                }

                Spacer()

                Button {
                    copyRepositoryLink()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(FlowCompactButtonStyle())
                .foregroundStyle(FlowBrand.steelBlue)
            }
            .font(.system(size: 10.5, weight: .medium))
        }
        .padding(13)
        .background(FlowCardBackground(radius: 16, emphasized: true))
    }

    private var primaryActionIsWorking: Bool {
        state.primaryDictationAction == .preparingModel
            || state.primaryDictationAction == .working
    }

    private var primaryActionIcon: String {
        switch state.primaryDictationAction {
        case .finish: return "checkmark"
        case .retry, .retryModel: return "arrow.clockwise"
        case .preparingModel: return "checkmark.shield"
        case .requestMicrophone, .start: return "mic.fill"
        case .requestAccessibility: return "cursorarrow.click.2"
        case .working: return "ellipsis"
        }
    }

    private var primaryActionLabel: String {
        switch state.primaryDictationAction {
        case .finish:
            return state.pipelineIsMeeting ? "Finish meeting" : "Finish dictation"
        case .retry:
            return state.failedRetryIsMeeting
                ? "Retry meeting transcription" : "Retry last dictation"
        case .preparingModel:
            return "Verifying speech model…"
        case .retryModel:
            return "Verify speech model"
        case .requestMicrophone:
            return "Allow microphone access"
        case .requestAccessibility:
            return "Review automatic typing"
        case .working:
            return state.pipelineIsMeeting ? "Finishing meeting…" : "Finishing dictation…"
        case .start:
            return "Start dictation"
        }
    }

    private var primaryActionHint: String {
        switch state.primaryDictationAction {
        case .start: return "Records from your microphone"
        case .finish:
            return state.pipelineIsMeeting
                ? "Stops recording and prepares meeting notes"
                : state.automaticInsertionEnabled
                    ? "Stops recording and inserts the dictated text"
                    : "Stops recording and shows the transcript in LockedIn Flow"
        case .retry: return "Retries the recording held in memory for this session"
        case .preparingModel:
            return "Dictation will be available after the provisioned model is verified"
        case .retryModel: return "Verifies the provisioned on-device speech model again"
        case .requestMicrophone: return "Requests macOS microphone permission"
        case .requestAccessibility:
            return "Explains optional Accessibility access before requesting it"
        case .working:
            return state.pipelineIsMeeting
                ? "Meeting notes are being prepared locally" : "Dictation is being finished locally"
        }
    }

    private var meetingActionDisabled: Bool {
        if state.isMeetingRecording { return false }
        return !state.modelReady
            || primaryActionIsWorking
            || state.pipelineState == .recording
    }

    private var meetingActionHint: String {
        if state.isMeetingRecording { return "Stop recording and prepare meeting notes" }
        if !state.modelReady { return "Available when the speech model is ready" }
        if primaryActionIsWorking || state.pipelineState == .recording {
            return "Available after the current recording finishes"
        }
        return "Records the room microphone and prepares notes on this Mac"
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(FlowBrand.tertiaryText)
                Spacer()
                FlowSignalMark()
                    .frame(width: 30, height: 14)
                    .opacity(state.canDictate ? 1 : 0.45)
            }

            StatusRow(
                label: "Model",
                value: modelStatusValue,
                ok: state.modelReady
            ) {
                if !state.modelReady && !state.modelSwitchInProgress {
                    Button("Setup guide") {
                        WindowOpener.shared.showModelSetup(state: state)
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("Open speech model setup instructions")
                }
            }
            StatusRow(
                label: "Mic",
                value: state.microphoneAuthorized ? "Allowed" : "Needed",
                ok: state.microphoneAuthorized
            ) {
                if !state.microphoneAuthorized {
                    Button("Grant") {
                        state.requestMicrophoneAccess()
                    }
                    .controlSize(.mini)
                }
            }
            StatusRow(
                label: "Output",
                value: state.automaticInsertionEnabled ? "Automatic typing" : "In-app transcript",
                ok: !state.automaticInsertionEnabled || state.accessibilityTrusted
            ) {
                if state.automaticInsertionEnabled {
                    Button("Use in-app") {
                        state.useInAppTranscription()
                    }
                    .controlSize(.mini)
                    .disabled(!state.canChangeTranscriptPolicy)
                }
            }
            StatusRow(label: "Profile", value: state.effectiveProfile.name, ok: true)
            if let target = state.targetAppName {
                StatusRow(label: "Target", value: target, ok: true)
            }
        }
        .padding(12)
        .background(FlowCardBackground(radius: 14))
    }

    private var lastDictationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Recent dictations")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(FlowBrand.tertiaryText)
                Spacer()
                Button("View all") {
                    state.showHistoryWindow()
                }
                .buttonStyle(FlowCompactButtonStyle())
                .foregroundStyle(FlowBrand.steelBlue)
            }

            ForEach(Array(state.historyEntries.prefix(3))) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.final)
                        .font(.system(size: 11.5))
                        .foregroundStyle(FlowBrand.primaryText)
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        Text(entry.createdAt, format: .dateTime.hour().minute())
                        if let app = entry.targetAppName {
                            Text("→ \(app)")
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Copy") {
                            copy(entry.final)
                        }
                        .buttonStyle(FlowCompactButtonStyle())
                        Button("Re-insert") {
                            state.reinsert(entry.final, sourceID: entry.id) { result in
                                switch result {
                                case .success(let outcome):
                                    if !outcome.requiresInspectionAcknowledgement {
                                        state.errorMessage = nil
                                        state.statusMessage = outcome.statusMessage
                                    }
                                case .failure(let error) where error is CancellationError:
                                    state.errorMessage = nil
                                    state.statusMessage = "Re-insertion canceled."
                                case .failure(let error) where error is ReinsertSafetyNoticeError:
                                    state.statusMessage = nil
                                    state.errorMessage = error.localizedDescription
                                case .failure(let error):
                                    state.statusMessage = nil
                                    state.errorMessage =
                                        "Couldn’t insert: \(error.localizedDescription)"
                                }
                            }
                        }
                        .buttonStyle(FlowCompactButtonStyle())
                        .disabled(
                            state.targetAppName == nil
                                || state.pendingReinsertInspection != nil
                        )
                        .help(
                            state.targetAppName.map { "Re-insert in \($0)" }
                                ?? "Focus an app first, then re-insert")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FlowBrand.tertiaryText)
                }
                .padding(10)
                .background(FlowBrand.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(FlowCardBackground(radius: 14))
    }

    private var modelStatusValue: String {
        if state.modelReady { return state.activeSpeechModelShortName }
        if state.primaryDictationAction == .retryModel { return "Unavailable" }
        return "Preparing…"
    }

    @ViewBuilder
    private var feedback: some View {
        if state.errorMessage != nil || state.statusMessage != nil
            || state.pendingReinsertInspection != nil || state.canRetryFailedDictation
            || state.vocabularyToast != nil
        {
            VStack(alignment: .leading, spacing: 7) {
                if let notice = state.pendingReinsertInspection {
                    Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FlowBrand.warning)
                } else if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FlowBrand.warning)
                } else if let status = state.statusMessage {
                    Text(status)
                        .foregroundStyle(FlowBrand.secondaryText)
                }

                if let toast = state.vocabularyToast {
                    HStack(spacing: 8) {
                        Label(toast.message, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(FlowBrand.success)
                        Spacer(minLength: 4)
                        Button("Undo") { state.undoLearnedCorrection() }
                            .buttonStyle(.plain)
                            .foregroundStyle(FlowBrand.secondaryText)
                            .underline()
                    }
                }

                if let notice = state.pendingReinsertInspection {
                    Button("I checked") {
                        state.acknowledgeReinsertInspection(notice)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("Clears this warning without inserting any text")
                }

                if state.canRetryFailedDictation {
                    Label("Recording held in memory for this session.", systemImage: "memorychip")
                        .foregroundStyle(FlowBrand.tertiaryText)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowBrand.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                state.showHomeWindow()
            } label: {
                Label("Home", systemImage: "house")
            }
            .buttonStyle(FlowCompactButtonStyle())

            Button {
                state.showHistoryWindow()
            } label: {
                Label("History", systemImage: "clock")
            }
            .buttonStyle(FlowCompactButtonStyle())

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(FlowCompactButtonStyle())

            Spacer()

            Button("Quit") {
                state.quit()
            }
            .buttonStyle(FlowCompactButtonStyle())
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(FlowBrand.secondaryText)
        .padding(.horizontal, 3)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        state.statusMessage = "Copied to clipboard"
    }

    private func copyRepositoryLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(
            "https://github.com/LockedinLabs-AI/lockedin-flow",
            forType: .string
        )
        state.statusMessage = "Project link copied"
    }
}

struct StatusRow<Accessory: View>: View {
    let label: String
    let value: String
    let ok: Bool
    @ViewBuilder var accessory: Accessory

    init(
        label: String,
        value: String,
        ok: Bool,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.label = label
        self.value = value
        self.ok = ok
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FlowBrand.tertiaryText)
                .frame(width: 52, alignment: .leading)
            Circle()
                .fill(ok ? FlowBrand.success : FlowBrand.warning)
                .frame(width: 5, height: 5)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(FlowBrand.secondaryText)
                .lineLimit(1)
            Spacer()
            accessory
        }
    }
}
