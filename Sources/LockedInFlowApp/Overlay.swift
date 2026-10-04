import AppKit
import Combine
import SwiftUI
import VoiceCore

/// How much of the floating bar is on screen.
enum BarVisibility: String, CaseIterable, Identifiable {
    /// Tiny idle handle always visible at the bottom of the screen (expands while dictating).
    case always
    /// Bar appears only during dictation and feedback.
    case whileDictating
    /// Nothing on screen, ever — hotkey and menu bar only.
    case never

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .always: return "Always show (compact handle)"
        case .whileDictating: return "Only while dictating"
        case .never: return "Never (hotkey only)"
        }
    }
}

/// The floating bar: a non-activating, draggable bottom-of-screen control surface.
/// Idle = tiny handle; dictating = full bar. Fades to 15% when the cursor approaches
/// so it never covers what you're trying to click. Visibility is driven reactively
/// from AppState — the pipeline never calls show/hide directly.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?

    private let activeSize = NSSize(width: 300, height: 68)
    private let idleSize = NSSize(width: 134, height: 42)
    private let fadeDistance: CGFloat = 110

    func attach(state: AppState) {
        if panel == nil { panel = makePanel(state: state) }
        state.$pipelineState
            .combineLatest(state.$barVisibility)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pipeline, visibility in
                self?.updateVisibility(pipeline: pipeline, visibility: visibility)
            }
            .store(in: &cancellables)
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private func isActive(_ pipeline: PipelineState) -> Bool {
        [.recording, .transcribing, .processing, .inserting, .done, .failed].contains(pipeline)
    }

    private func updateVisibility(pipeline: PipelineState, visibility: BarVisibility) {
        let active = isActive(pipeline)
        let shouldShow: Bool
        switch visibility {
        case .always: shouldShow = true
        case .whileDictating: shouldShow = active
        case .never: shouldShow = false
        }
        resize(active: active)
        if shouldShow { show() } else { hide() }
    }

    private func show() {
        if let panel { clampToVisibleFrame(panel) }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel(state: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: state.pipelineState == .idle || state.pipelineState == .ready
                    ? idleSize : activeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: FloatingBarView().environmentObject(state))

        if let x = UserDefaults.standard.object(forKey: "barOriginX") as? CGFloat,
            let y = UserDefaults.standard.object(forKey: "barOriginY") as? CGFloat
        {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            positionAtBottomOfActiveScreen(panel)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel else { return }
                self.clampToVisibleFrame(panel)
                UserDefaults.standard.set(panel.frame.origin.x, forKey: "barOriginX")
                UserDefaults.standard.set(panel.frame.origin.y, forKey: "barOriginY")
            }
        }

        // Proximity fade: duck out of the way when the cursor comes close.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self, weak panel] _ in
            Task { @MainActor in
                self?.updateProximityFade(panel: panel)
            }
        }
        return panel
    }

    private func updateProximityFade(panel: NSPanel?) {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        // Hovering the bar itself: fully solid — never vanish under the user's cursor.
        // Only fade when the cursor is NEAR the bar, so content behind it shows through.
        let target: CGFloat
        if accessibilityPrefersOpaqueUI || panel.frame.contains(mouse) {
            target = 1.0
        } else if panel.frame.insetBy(dx: -fadeDistance, dy: -fadeDistance).contains(mouse) {
            // Keep the recorder unmistakably present even while it ducks out of
            // the way. A near-invisible recording control is easy to lose.
            target = 0.68
        } else {
            target = 1.0
        }
        guard panel.alphaValue != target else { return }
        if accessibilityReduceMotion {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = target
        }
    }

    private func resize(active: Bool) {
        guard let panel else { return }
        let size = active ? activeSize : idleSize
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        if accessibilityReduceMotion {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func positionAtBottomOfActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.minY + 72
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The bar can be dragged, but never lost: after every move it is clamped
    /// inside the screen's visible frame (Dock and menu bar excluded).
    private func clampToVisibleFrame(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var frame = panel.frame
        if frame.maxX > visible.maxX - margin {
            frame.origin.x = visible.maxX - margin - frame.width
        }
        if frame.minX < visible.minX + margin { frame.origin.x = visible.minX + margin }
        if frame.maxY > visible.maxY - margin {
            frame.origin.y = visible.maxY - margin - frame.height
        }
        if frame.minY < visible.minY + margin { frame.origin.y = visible.minY + margin }
        if frame != panel.frame {
            panel.setFrame(frame, display: true, animate: !accessibilityReduceMotion)
        }
    }

    private var accessibilityReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var accessibilityPrefersOpaqueUI: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Clears the saved drag position and snaps the bar back to bottom-center.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "barOriginX")
        UserDefaults.standard.removeObject(forKey: "barOriginY")
        if let panel {
            positionAtBottomOfActiveScreen(panel)
            clampToVisibleFrame(panel)
        }
    }
}

// MARK: - Bar UI

struct FloatingBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool {
        [.recording, .transcribing, .processing, .inserting, .done, .failed].contains(
            state.pipelineState)
    }
    private var isRecording: Bool { state.pipelineState == .recording }
    private var isWorking: Bool {
        [.transcribing, .processing, .inserting].contains(state.pipelineState)
    }

    var body: some View {
        Group {
            if isActive {
                activeBar
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                idleHandle
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isActive)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Idle — tiny handle

    private var idleHandle: some View {
        HStack(spacing: 3) {
            Button {
                state.performPrimaryDictationAction()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(FlowBrand.controlStrong)
                        Circle().strokeBorder(FlowBrand.lineStrong, lineWidth: 0.7)
                        Image(systemName: idleActionSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(idleActionColor)
                    }
                    .frame(width: 26, height: 26)

                    FlowSignalMark()
                        .frame(width: 38, height: 19)
                        .opacity(state.primaryDictationAction == .start ? 1 : 0.42)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .background(
                    FlowBrand.controlStrong.opacity(0.30),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!state.primaryDictationAction.isEnabled)
            .help(idleActionHint)
            .accessibilityLabel(idleActionLabel)
            .accessibilityHint(idleActionHint)

            Button {
                state.showHistoryWindow()
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Recent dictations")
            .accessibilityLabel("Recent dictations")
        }
        .padding(3)
        .frame(width: 134, height: 42)
        .background(CardGlassBackground(radius: 14, recording: false))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FlowBrand.line, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    // MARK: Active — listening card

    private var activeBar: some View {
        HStack(spacing: 10) {
            leadingControl

            if isRecording {
                Button {
                    state.controller.toggleFromBar()
                } label: {
                    HStack(spacing: 10) {
                        activityContent

                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(FlowBrand.background)
                            .frame(width: 34, height: 34)
                            .background(FlowBrand.primaryText, in: Circle())
                            .shadow(color: .black.opacity(0.34), radius: 6, y: 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    state.pipelineIsMeeting
                        ? "Click anywhere on the waveform to stop and save meeting notes"
                        : "Click anywhere on the waveform to stop and insert"
                )
                .accessibilityLabel(
                    state.pipelineIsMeeting
                        ? "Stop meeting and save notes" : "Stop dictation and insert text"
                )
                .accessibilityHint("The entire listening area is clickable")
            } else if state.pipelineState == .failed && activeRecoveryActionAvailable {
                Button {
                    state.performPrimaryDictationAction()
                } label: {
                    HStack(spacing: 10) {
                        activityContent

                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(FlowBrand.primaryText)
                            .frame(width: 34, height: 34)
                            .background(FlowBrand.controlStrong, in: Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(idleActionHint)
                .accessibilityLabel(idleActionLabel)
                .accessibilityHint(idleActionHint)
            } else {
                activityContent
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 300, height: 68)
        .background(CardGlassBackground(radius: 18, recording: isRecording))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isRecording
                        ? AnyShapeStyle(FlowBrand.lineStrong)
                        : AnyShapeStyle(FlowBrand.line),
                    lineWidth: isRecording ? 1 : 0.7
                )
        )
        .shadow(
            color: .black.opacity(isRecording ? 0.48 : 0.35),
            radius: isRecording ? 16 : 12,
            y: 4
        )
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(statusLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isRecording {
                    TimelineView(.periodic(from: state.recordingStartedAt ?? Date(), by: 0.5)) {
                        context in
                        Text(elapsedString(at: context.date))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(FlowBrand.tertiaryText)
                    }
                } else {
                    FlowSignalMark()
                        .frame(width: 24, height: 12)
                        .opacity(isWorking ? 0.55 : 0.9)
                }
            }

            if isRecording {
                LevelMeter(
                    level: state.level,
                    barCount: 25,
                    previewSignal: state.isMarketingPreview
                )
                .frame(height: 19)
                .accessibilityHidden(true)
            } else if isWorking {
                IndeterminateLine()
                    .frame(height: 19)
                    .accessibilityLabel(
                        state.pipelineIsMeeting ? "Meeting processing" : "Dictation processing")
            } else {
                Capsule()
                    .fill(statusColor.opacity(0.24))
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if isRecording {
            Button {
                state.controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(FlowBrand.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(FlowBrand.surfaceStrong, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FlowBrand.line, lineWidth: 0.7)
                    }
            }
            .buttonStyle(.plain)
            .help(state.pipelineIsMeeting ? "Discard meeting recording" : "Discard dictation")
            .accessibilityLabel(
                state.pipelineIsMeeting ? "Discard meeting recording" : "Discard dictation")
        } else if isWorking {
            ProgressView()
                .controlSize(.small)
                .tint(FlowBrand.steelBlue)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: terminalSymbol)
                .foregroundStyle(
                    state.pipelineState == .failed
                        ? FlowBrand.warning
                        : meetingWasDeleted ? FlowBrand.secondaryText : FlowBrand.success
                )
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .background(statusColor.opacity(0.12), in: Circle())
        }
    }

    private var statusLabel: String {
        switch state.pipelineState {
        case .recording:
            if state.isMarketingPreview { return "Listening" }
            if state.pipelineIsMeeting {
                return state.controller.isVoiceProcessingActive
                    ? "Meeting · voice focused" : "Meeting recording"
            }
            return state.controller.isVoiceProcessingActive
                ? "Listening · voice focused" : "Listening"
        case .done:
            if state.pipelineIsMeeting {
                if meetingWasDeleted { return "Meeting deleted" }
                if state.statusMessage?.hasPrefix("Meeting saved without a summary.") == true {
                    return "Meeting transcript saved"
                }
                if state.statusMessage == "Meeting notes ready." { return "Meeting notes ready" }
                return "Meeting finished"
            }
            return state.automaticInsertionEnabled ? "Inserted" : "Transcript ready"
        case .failed:
            return state.errorMessage
                ?? (state.pipelineIsMeeting ? "Meeting failed" : "Dictation failed")
        case .transcribing:
            return state.pipelineIsMeeting ? "Transcribing meeting…" : "Transcribing…"
        case .processing:
            return state.pipelineIsMeeting ? "Preparing notes…" : "Cleaning up…"
        case .inserting: return "Inserting…"
        default: return "Working…"
        }
    }

    private var statusColor: Color {
        switch state.pipelineState {
        case .recording: return FlowBrand.primaryText
        case .done: return meetingWasDeleted ? FlowBrand.secondaryText : FlowBrand.success
        case .failed: return FlowBrand.warning
        default: return FlowBrand.secondaryText
        }
    }

    private var meetingWasDeleted: Bool {
        state.pipelineIsMeeting
            && state.statusMessage == "Meeting was deleted before notes finished."
    }

    private var activeRecoveryActionAvailable: Bool {
        state.primaryDictationAction == .retry || state.primaryDictationAction == .retryModel
    }

    private var terminalSymbol: String {
        if state.pipelineState == .failed { return "exclamationmark.triangle" }
        if meetingWasDeleted { return "trash" }
        return "checkmark"
    }

    private var idleActionSymbol: String {
        switch state.primaryDictationAction {
        case .retry, .retryModel: return "arrow.clockwise"
        case .preparingModel: return "checkmark.shield"
        case .requestAccessibility: return "cursorarrow.click.2"
        default: return "mic.fill"
        }
    }

    private var idleActionColor: Color {
        switch state.primaryDictationAction {
        case .retryModel: return FlowBrand.warning
        default: return FlowBrand.primaryText
        }
    }

    private var idleActionLabel: String {
        switch state.primaryDictationAction {
        case .start: return "Start dictation"
        case .retry:
            return state.failedRetryIsMeeting
                ? "Retry meeting transcription" : "Retry last dictation"
        case .preparingModel: return "Verifying speech model"
        case .retryModel: return "Verify speech model"
        case .requestMicrophone: return "Allow microphone access"
        case .requestAccessibility: return "Review automatic typing"
        case .finish: return state.pipelineIsMeeting ? "Finish meeting" : "Finish dictation"
        case .working: return state.pipelineIsMeeting ? "Finishing meeting" : "Finishing dictation"
        }
    }

    private var idleActionHint: String {
        switch state.primaryDictationAction {
        case .start: return "Records from your microphone"
        case .retry: return "Retries the recording held in memory for this session"
        case .preparingModel:
            return "Dictation will be available after the provisioned model is verified"
        case .retryModel: return "Verifies the provisioned on-device speech model again"
        case .requestMicrophone: return "Requests macOS microphone permission"
        case .requestAccessibility:
            return "Explains optional Accessibility access before requesting it"
        case .finish: return "Stops the current recording"
        case .working: return "The current recording is being finished locally"
        }
    }

    private func elapsedString(at date: Date) -> String {
        if state.isMarketingPreview { return "0:11" }
        guard let started = state.recordingStartedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Slim indeterminate progress line shown while transcribing / cleaning up / inserting.
private struct IndeterminateLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var go = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FlowBrand.line)
                Capsule().fill(FlowBrand.steelBlue)
                    .frame(width: geo.size.width * 0.32)
                    .offset(x: go ? geo.size.width * 0.68 : 0)
            }
            .frame(width: geo.size.width, height: 4)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if reduceMotion {
                go = true
            } else {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    go = true
                }
            }
        }
    }
}

/// Card surface: Liquid Glass on macOS 26+, thin material on older systems.
/// The neutral glass keeps the live waveform as the sole saturated listening cue.
private struct CardGlassBackground: View {
    let radius: CGFloat
    let recording: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            ZStack {
                shape.fill(FlowBrand.backgroundRaised.opacity(recording ? 0.94 : 0.90))
                shape
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(
                            recording
                                ? FlowBrand.surfaceStrong.opacity(0.46)
                                : FlowBrand.background.opacity(0.66)
                        ),
                        in: shape
                    )
            }
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(FlowBrand.backgroundRaised.opacity(recording ? 0.76 : 0.64))
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let barCount: Int
    let previewSignal: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rolling history of recent input levels — rendered as a mirrored,
    /// studio-style waveform that dances with your voice.
    @State private var history: [Float]
    @State private var liveLevel: Float

    init(level: Float, barCount: Int = 20, previewSignal: Bool = false) {
        self.level = level
        self.barCount = barCount
        self.previewSignal = previewSignal
        let previewPattern: [Float] = [
            0.18, 0.34, 0.58, 0.76, 0.46, 0.28, 0.66, 0.91, 0.54, 0.38,
            0.72, 0.49, 0.83, 0.61, 0.31, 0.57, 0.88, 0.68, 0.42, 0.74,
            0.52, 0.29, 0.63, 0.44, 0.22,
        ]
        _history = State(
            initialValue: previewSignal
                ? Array(previewPattern.prefix(barCount))
                : Array(repeating: 0, count: barCount)
        )
        _liveLevel = State(initialValue: level)
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let spacing: CGFloat = 2.2
            let barWidth = max(
                2,
                (size.width - spacing * CGFloat(max(0, history.count - 1)))
                    / CGFloat(max(1, history.count))
            )
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [FlowBrand.violet, FlowBrand.indigo, FlowBrand.cyan]),
                startPoint: CGPoint(x: 0, y: mid),
                endPoint: CGPoint(x: size.width, y: mid)
            )

            for (index, value) in history.enumerated() {
                let recency = CGFloat(index) / CGFloat(max(1, history.count - 1))
                let height = max(2.5, min(size.height, CGFloat(value) * size.height * 0.92))
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: mid - height / 2,
                    width: barWidth,
                    height: height
                )
                var barContext = context
                barContext.opacity = 0.28 + 0.72 * recency
                barContext.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: gradient
                )
            }
        }
        .shadow(color: FlowBrand.indigo.opacity(0.30), radius: 2)
        .onChange(of: level, initial: true) { _, newLevel in
            liveLevel = newLevel
            if reduceMotion && !previewSignal {
                history = Array(repeating: newLevel, count: barCount)
            }
        }
        .task(id: reduceMotion) {
            guard !previewSignal else { return }
            guard !reduceMotion else {
                history = Array(repeating: liveLevel, count: barCount)
                return
            }
            // Re-sample the input level at display rate with a fast-attack /
            // slow-release envelope. Audio callbacks arrive ~12×/s; advancing the
            // history every frame is what makes the wave visibly alive — punchy
            // rise when you speak, smooth fall when you pause.
            var envelope: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                let sample = liveLevel
                envelope = sample > envelope ? sample : envelope * 0.82
                history.append(envelope)
                if history.count > barCount { history.removeFirst() }
            }
        }
    }
}
