import AppKit
import SwiftUI
import VoiceCore

private struct HomeHeaderBackground: View {
    var body: some View {
        FlowDepthBackdrop()
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.11))
                    .frame(height: 1)
            }
    }
}

/// The main LockedIn Flow window is deliberately an instrument, not a
/// dashboard: one primary dictation surface, a readable recent-work sheet, and
/// quiet usage context.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focusedDeck: DeckFocus?

    private enum DeckFocus: Hashable {
        case ready
        case discardRecording
        case finishRecording
        case discardRetry
        case retry
    }

    private var isRecording: Bool { state.pipelineState == .recording }
    private var isWorking: Bool {
        [.transcribing, .processing, .inserting].contains(state.pipelineState)
    }
    private var journeyPhase: FlowJourneyPhase {
        if state.canRetryFailedDictation { return .captured }
        switch state.pipelineState {
        case .recording:
            return .listening
        case .transcribing, .processing:
            return .onDevice
        case .inserting:
            return .cursor
        case .done:
            if state.pipelineIsMeeting && !meetingNotesCompletionConfirmed {
                return .ready
            }
            return .complete
        default:
            return .ready
        }
    }

    /// Meeting completion is inferred conservatively from the outcome copy
    /// already published by the controller. Unknown or deleted outcomes do not
    /// receive a completed Notes checkmark.
    private var meetingNotesCompletionConfirmed: Bool {
        guard state.pipelineIsMeeting, let status = state.statusMessage else { return false }
        return status == "Meeting notes ready."
            || status.hasPrefix("Meeting saved without a summary.")
    }

    private var journeyDestination: FlowJourneyDestination {
        state.pipelineIsMeeting || (state.canRetryFailedDictation && state.failedRetryIsMeeting)
            ? .notes
            : state.automaticInsertionEnabled ? .cursor : .transcript
    }

    private var journeyAccessibilityStatus: String? {
        if state.canRetryFailedDictation {
            return state.failedRetryIsMeeting
                ? "Meeting recording held in memory for this session"
                : "Dictation recording held in memory for this session"
        }
        if !state.modelReady {
            return state.primaryDictationAction == .retryModel
                ? "Speech model setup needs attention"
                : "Verifying the provisioned speech model on this Mac"
        }
        if !state.microphoneAuthorized { return "Microphone access is required" }
        if state.automaticInsertionEnabled && !state.accessibilityTrusted {
            return "Accessibility permission is required for text insertion"
        }
        if state.pipelineState == .failed { return "Dictation needs attention" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(HomeHeaderBackground())

            if state.isMarketingPreview {
                homeContent
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(FlowWorkspace.canvas)
            } else {
                ScrollView {
                    homeContent
                }
                .scrollIndicators(.hidden)
                .background(FlowWorkspace.canvas)
            }
        }
        .background(FlowWorkspace.canvas)
        .frame(minWidth: 600, minHeight: 630)
        .preferredColorScheme(.light)
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if state.shouldShowShortcutMigrationNotice {
                shortcutMigrationNotice
            }
            if let notice = state.pendingReinsertInspection {
                reinsertInspectionNotice(notice)
            }
            dictationDeck
            recents
            usageSummary
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
    }

    private func reinsertInspectionNotice(
        _ notice: ReinsertInspectionNotice
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(FlowWorkspace.danger)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text("Check the original insertion")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Text(notice.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowWorkspace.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("I checked") {
                state.acknowledgeReinsertInspection(notice)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityHint("Clears this warning without inserting any text")
        }
        .padding(16)
        .background(FlowWorkspaceSurface(radius: 14, emphasized: true))
        .accessibilityElement(children: .contain)
    }

    private var shortcutMigrationNotice: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(FlowWorkspace.action)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text("Your dictation shortcut changed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Text(
                    "LockedIn Flow moved the old bare-Fn shortcut to Control-Shift-Space to avoid the common shortcut conflict with other dictation apps. You can change it in Settings → General → Activation."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(FlowWorkspace.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                SettingsLink {
                    Label("Shortcut Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Got it") {
                    state.dismissShortcutMigrationNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(FlowWorkspace.secondaryText)
                .underline()
            }
        }
        .padding(16)
        .background(FlowWorkspaceSurface(radius: 14, emphasized: true))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 17) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.42), radius: 18, y: 9)
                .shadow(color: .black.opacity(0.30), radius: 3, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                FlowBrandTitle()
                Text("Private dictation. Polished on your Mac.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(FlowBrand.secondaryText)
            }

            Spacer()
        }
    }

    private var dictationDeck: some View {
        ZStack {
            FlowInstrumentSurface(active: isRecording)

            VStack(spacing: 0) {
                ZStack {
                    if isRecording {
                        recordingDeck
                    } else if isWorking {
                        workingDeck
                    } else if !state.modelReady {
                        if state.primaryDictationAction == .retryModel {
                            modelUnavailableDeck
                        } else {
                            preparingDeck
                        }
                    } else if state.canRetryFailedDictation {
                        retryDeck
                    } else {
                        readyDeck
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                journeyRail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 144)
    }

    private var journeyRailContent: some View {
        FlowPipelineRail(
            phase: journeyPhase,
            destination: journeyDestination,
            accessibilityStatus: journeyAccessibilityStatus
        )
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var journeyRail: some View {
        if isRecording {
            Button {
                state.controller.toggleFromBar()
            } label: {
                journeyRailContent
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
        } else if state.canRetryFailedDictation {
            Button {
                state.retryFailedDictation()
            } label: {
                journeyRailContent
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
        } else if !isWorking
            && state.modelReady
            && (!state.microphoneAuthorized || !state.accessibilityTrusted
                || state.canStartDictation)
        {
            Button {
                performReadyAction()
            } label: {
                journeyRailContent
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
        } else {
            journeyRailContent
        }
    }

    private var readyDeck: some View {
        Button {
            performReadyAction()
        } label: {
            HStack(spacing: 17) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    Image(systemName: readySymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(readyColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(readinessTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FlowBrand.primaryText)
                    Text(readinessDetail)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(FlowBrand.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 7) {
                    FlowReactiveSignal(level: 0.22, active: state.canStartDictation)
                        .frame(width: 58, height: 30)
                    if state.canStartDictation {
                        Text(state.activationHint)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(FlowBrand.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if focusedDeck == .ready {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(FlowBrand.darkFocus, lineWidth: 2)
                        .padding(3)
                }
            }
        }
        .buttonStyle(FlowDeckButtonStyle())
        .focused($focusedDeck, equals: .ready)
        .help(state.canStartDictation ? "Start dictation" : readinessDetail)
        .accessibilityLabel(readinessTitle)
        .accessibilityHint(
            state.canDictate ? "Starts recording from your microphone" : readinessDetail)
    }

    private var recordingDeck: some View {
        HStack(spacing: 12) {
            Button {
                state.controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(FlowBrand.surfaceStrong, in: Circle())
                    .overlay {
                        Circle().strokeBorder(FlowBrand.line, lineWidth: 0.8)
                    }
                    .overlay {
                        if focusedDeck == .discardRecording {
                            Circle()
                                .strokeBorder(FlowBrand.darkFocus, lineWidth: 2)
                                .padding(-3)
                        }
                    }
            }
            .buttonStyle(FlowDeckButtonStyle())
            .focused($focusedDeck, equals: .discardRecording)
            .help(state.pipelineIsMeeting ? "Discard meeting recording" : "Discard dictation")
            .accessibilityLabel(
                state.pipelineIsMeeting ? "Discard meeting recording" : "Discard dictation")

            Button {
                state.controller.toggleFromBar()
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(state.pipelineIsMeeting ? "Meeting recording" : "Listening")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(FlowBrand.primaryText)

                            if state.controller.isVoiceProcessingActive {
                                Text("VOICE FOCUS")
                                    .font(
                                        .system(size: 8.5, weight: .semibold, design: .monospaced)
                                    )
                                    .foregroundStyle(FlowBrand.tertiaryText)
                            }

                            Spacer()

                            TimelineView(
                                .periodic(from: state.recordingStartedAt ?? Date(), by: 0.5)
                            ) {
                                context in
                                Text(elapsedString(at: context.date))
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(FlowBrand.tertiaryText)
                            }
                        }

                        FlowReactiveSignal(level: state.level, active: true)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                    }

                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(FlowBrand.background)
                        .frame(width: 36, height: 36)
                        .background(FlowBrand.primaryText, in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    if focusedDeck == .finishRecording {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(FlowBrand.darkFocus, lineWidth: 2)
                            .padding(-3)
                    }
                }
            }
            .buttonStyle(FlowDeckButtonStyle())
            .focused($focusedDeck, equals: .finishRecording)
            .help(
                state.pipelineIsMeeting
                    ? "Click the recording area to stop and save meeting notes"
                    : state.automaticInsertionEnabled
                        ? "Click the listening area to stop and insert"
                        : "Click the listening area to stop and view your transcript"
            )
            .accessibilityLabel(
                state.pipelineIsMeeting
                    ? "Stop meeting and save notes"
                    : state.automaticInsertionEnabled
                        ? "Stop dictation and insert text" : "Stop dictation and show transcript"
            )
            .accessibilityHint("The entire listening area is clickable")
        }
        .padding(.horizontal, 16)
    }

    private var preparingDeck: some View {
        HStack(spacing: 17) {
            ProgressView()
                .controlSize(.regular)
                .tint(FlowBrand.steelBlue)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Verifying your speech model")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlowBrand.primaryText)
                Text(state.modelStatus)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }

    private var modelUnavailableDeck: some View {
        HStack(spacing: 17) {
            ZStack {
                Circle().fill(FlowBrand.warning.opacity(0.12))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FlowBrand.warning)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("Speech model unavailable")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlowBrand.primaryText)
                Text(state.errorMessage ?? state.modelStatus)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 14)

            Button("Set up models") {
                WindowOpener.shared.showModelSetup(state: state)
            }
            .buttonStyle(.borderedProminent)
            .tint(FlowBrand.primaryText)
            .foregroundStyle(FlowBrand.background)
            .controlSize(.regular)
            .accessibilityHint(
                "Opens local model setup and recheck instructions without downloading or recording")
        }
        .padding(.horizontal, 22)
    }

    private var workingDeck: some View {
        HStack(spacing: 17) {
            ProgressView()
                .controlSize(.regular)
                .tint(FlowBrand.steelBlue)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(workingTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlowBrand.primaryText)
                Text("Finishing locally. Your audio is never sent to a server.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowBrand.secondaryText)
            }

            Spacer()

            FlowReactiveSignal(level: 0.28, active: false)
                .frame(width: 52, height: 28)
                .opacity(0.58)
        }
        .padding(.horizontal, 22)
    }

    private var retryDeck: some View {
        HStack(spacing: 12) {
            Button {
                state.discardFailedDictation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(FlowBrand.surfaceStrong, in: Circle())
                    .overlay {
                        Circle().strokeBorder(FlowBrand.line, lineWidth: 0.8)
                    }
                    .overlay {
                        if focusedDeck == .discardRetry {
                            Circle()
                                .strokeBorder(FlowBrand.darkFocus, lineWidth: 2)
                                .padding(-3)
                        }
                    }
            }
            .buttonStyle(FlowDeckButtonStyle())
            .focused($focusedDeck, equals: .discardRetry)
            .help("Discard failed recording")
            .accessibilityLabel("Discard failed recording")

            Button {
                state.retryFailedDictation()
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(FlowBrand.warning.opacity(0.12))
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FlowBrand.warning)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            state.failedRetryIsMeeting
                                ? "Retry meeting transcription" : "Retry last dictation"
                        )
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FlowBrand.primaryText)
                        Text(state.errorMessage ?? "The last local transcription did not finish.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowBrand.secondaryText)
                            .lineLimit(1)
                        Text("Recording held in memory for this session only.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(FlowBrand.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("Retry")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(FlowBrand.background)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(FlowBrand.primaryText, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    if focusedDeck == .retry {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(FlowBrand.darkFocus, lineWidth: 2)
                            .padding(-3)
                    }
                }
            }
            .buttonStyle(FlowDeckButtonStyle())
            .focused($focusedDeck, equals: .retry)
            .help(
                state.failedRetryIsMeeting
                    ? "Retry meeting transcription from the session-only recording"
                    : "Retry transcription from the session-only recording"
            )
            .accessibilityLabel(
                state.failedRetryIsMeeting ? "Retry meeting transcription" : "Retry last dictation"
            )
            .accessibilityHint(
                "Reprocesses the recording held in memory for this session, without recording again"
            )
        }
        .padding(.horizontal, 16)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent dictations")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Spacer()
                if !state.historyEntries.isEmpty {
                    Button("View all") {
                        state.showHistoryWindow()
                    }
                    .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.action)
                }
            }

            VStack(spacing: 0) {
                if state.historyEntries.isEmpty {
                    emptyRecents
                } else {
                    ForEach(Array(state.historyEntries.prefix(4).enumerated()), id: \.element.id) {
                        index, entry in
                        if index > 0 {
                            Divider().overlay(FlowWorkspace.line)
                        }
                        RecentDictationRow(
                            entry: entry,
                            currentTargetAppName: state.targetAppName,
                            onCopy: { copy(entry.final) },
                            onReinsert: { completion in
                                state.reinsert(
                                    entry.final,
                                    sourceID: entry.id,
                                    completion: completion
                                )
                            },
                            reinsertBlocked: state.pendingReinsertInspection != nil
                                || !state.automaticInsertionEnabled,
                            ownedInspection: state.pendingReinsertInspection.flatMap {
                                $0.sourceID == entry.id ? $0 : nil
                            }
                        )
                    }
                }
            }
            .background(FlowWorkspaceSurface(radius: 17))
        }
    }

    private var emptyRecents: some View {
        HStack(spacing: 15) {
            Image(systemName: "text.quote")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(FlowWorkspace.action)
                .frame(width: 42, height: 42)
                .background(FlowWorkspace.surfaceRaised, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Your first polished thought will appear here.")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Text("Use \(state.activationHint), speak naturally, then finish.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowWorkspace.secondaryText)
            }
            Spacer()
        }
        .padding(18)
    }

    private var usageSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .semibold))
            Text("Speech recognition and cleanup run on this Mac")
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text("No cloud audio")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(FlowWorkspace.tertiaryText)
        .padding(.horizontal, 3)
    }

    private var readinessTitle: String {
        if !state.modelReady { return "Verifying your speech model" }
        if !state.microphoneAuthorized { return "Allow microphone access" }
        if state.automaticInsertionEnabled && !state.accessibilityTrusted {
            return "Review automatic typing"
        }
        if state.pipelineState == .failed { return "Ready to try again" }
        if state.pipelineState == .done { return "Ready for your next thought" }
        return "Start dictation"
    }

    private var readinessDetail: String {
        if !state.modelReady { return state.modelStatus }
        if !state.microphoneAuthorized { return "LockedIn Flow needs the microphone to hear you." }
        if state.automaticInsertionEnabled && !state.accessibilityTrusted {
            return
                "Use in-app transcription without Accessibility, or review optional automatic typing."
        }
        if state.pipelineState == .failed, let error = state.errorMessage { return error }
        if !state.automaticInsertionEnabled {
            return "Transcribe here, then choose Copy. No Accessibility access required."
        }
        let cleanup = state.cleanupEnabled ? "polished locally" : "transcribed directly"
        return "\(state.effectiveProfile.name) profile · \(cleanup)"
    }

    private var readySymbol: String {
        if state.pipelineState == .failed { return "arrow.clockwise" }
        if !state.modelReady { return "checkmark.shield" }
        if !state.canDictate { return "exclamationmark" }
        return "mic.fill"
    }

    private var readyColor: Color {
        if state.pipelineState == .failed || !state.canStartDictation { return FlowBrand.warning }
        return FlowBrand.primaryText
    }

    private var workingTitle: String {
        if state.pipelineIsMeeting {
            switch state.pipelineState {
            case .transcribing: return "Transcribing meeting"
            case .processing: return "Preparing meeting notes"
            default: return "Saving meeting"
            }
        }
        switch state.pipelineState {
        case .transcribing: return "Transcribing"
        case .processing: return "Polishing your words"
        case .inserting: return "Placing text at the cursor"
        default: return "Finishing dictation"
        }
    }

    private func elapsedString(at date: Date) -> String {
        if state.isMarketingPreview { return "0:11" }
        guard let started = state.recordingStartedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }

    private func performReadyAction() {
        state.performPrimaryDictationAction()
    }
}

/// A five-bar level response that uses only compositor scaling. It intentionally
/// avoids a second rolling waveform task alongside the floating recorder.
private struct FlowReactiveSignal: View {
    let level: Float
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let baseHeights: [CGFloat] = [0.42, 0.70, 1.0, 0.70, 0.42]

    var body: some View {
        GeometryReader { geometry in
            let gap = max(3, geometry.size.width * 0.055)
            let barWidth = max(
                3,
                (geometry.size.width - gap * CGFloat(baseHeights.count - 1))
                    / CGFloat(baseHeights.count)
            )

            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(baseHeights.enumerated()), id: \.offset) { index, base in
                    let response = max(
                        0.18, min(1, CGFloat(level) * (1.15 + CGFloat(index % 3) * 0.22)))
                    Capsule(style: .continuous)
                        .frame(width: barWidth, height: max(barWidth, geometry.size.height * base))
                        .scaleEffect(
                            y: reduceMotion ? 0.62 : active ? 0.34 + response * 0.66 : 0.48,
                            anchor: .center
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(FlowBrand.spectrum)
            .opacity(active ? 1 : 0.62)
        }
        .accessibilityHidden(true)
    }
}

private struct RecentDictationRow: View {
    let entry: HistoryEntry
    let currentTargetAppName: String?
    let onCopy: () -> Void
    let onReinsert: (@escaping (Result<ReinsertSuccess, Error>) -> Void) -> Void
    let reinsertBlocked: Bool
    let ownedInspection: ReinsertInspectionNotice?

    @State private var copied = false
    @State private var reinsertionMessage: String?
    @State private var reinsertionDetail: String?
    @State private var reinsertionFailed = false
    @State private var reinsertionCanceled = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.final)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(FlowWorkspace.primaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(entry.createdAt, format: .dateTime.hour().minute())
                    if let app = entry.targetAppName {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                    if let reinsertionMessage {
                        Text("·")
                        Text(reinsertionMessage)
                            .foregroundStyle(
                                reinsertionFailed
                                    ? FlowWorkspace.danger
                                    : reinsertionCanceled
                                        ? FlowWorkspace.secondaryText
                                        : FlowWorkspace.success
                            )
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(FlowWorkspace.tertiaryText)
            }

            HStack(spacing: 6) {
                Button {
                    onCopy()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            copied ? FlowWorkspace.success : FlowWorkspace.secondaryText
                        )
                        .frame(width: 30, height: 30)
                        .background(FlowWorkspace.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy dictation")
                .accessibilityLabel(copied ? "Copied" : "Copy dictation")

                Button {
                    onReinsert { result in
                        switch result {
                        case .success(let outcome):
                            reinsertionMessage = outcome.compactMessage
                            reinsertionDetail = nil
                            reinsertionFailed = false
                            reinsertionCanceled = false
                        case .failure(let error) where error is CancellationError:
                            reinsertionMessage = "Canceled"
                            reinsertionDetail = nil
                            reinsertionFailed = false
                            reinsertionCanceled = true
                        case .failure(let error) where error is ReinsertSafetyNoticeError:
                            reinsertionMessage = "Check insertion"
                            reinsertionDetail = error.localizedDescription
                            reinsertionFailed = true
                            reinsertionCanceled = false
                        case .failure(let error):
                            reinsertionMessage = "Couldn’t insert"
                            reinsertionDetail = error.localizedDescription
                            reinsertionFailed = true
                            reinsertionCanceled = false
                        }
                    }
                } label: {
                    Image(
                        systemName: reinsertionFailed
                            ? "exclamationmark"
                            : reinsertionCanceled
                                ? "xmark"
                                : reinsertionMessage == nil
                                    ? "arrow.turn.down.right"
                                    : "checkmark"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        reinsertionFailed
                            ? FlowWorkspace.danger
                            : reinsertionCanceled || reinsertionMessage == nil
                                ? FlowWorkspace.secondaryText
                                : FlowWorkspace.success
                    )
                    .frame(width: 30, height: 30)
                    .background(FlowWorkspace.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(currentTargetAppName == nil || reinsertBlocked)
                .help(
                    reinsertionDetail ?? currentTargetAppName.map { "Re-insert in \($0)" }
                        ?? "Focus an app first, then re-insert"
                )
                .accessibilityLabel(
                    reinsertionMessage
                        ?? currentTargetAppName.map { "Re-insert in \($0)" }
                        ?? "Re-insert unavailable; focus an app first"
                )
                .accessibilityHint(reinsertionDetail ?? "Places this dictation in the focused app")
                .onChange(of: ownedInspection) { oldInspection, newInspection in
                    if oldInspection != nil, newInspection == nil {
                        reinsertionMessage = nil
                        reinsertionDetail = nil
                        reinsertionFailed = false
                        reinsertionCanceled = false
                    }
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
    }
}
