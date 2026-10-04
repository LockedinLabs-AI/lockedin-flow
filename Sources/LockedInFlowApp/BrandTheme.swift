import SwiftUI

/// Shared visual language for LockedIn Flow's native surfaces.
///
/// Keeping the palette here prevents the Home window, menu-bar panel, and
/// floating dictation pill from drifting into separate product identities.
enum FlowBrand {
    static let background = Color(red: 0.030, green: 0.036, blue: 0.047)
    static let backgroundRaised = Color(red: 0.054, green: 0.064, blue: 0.080)
    static let surface = Color(red: 0.078, green: 0.091, blue: 0.112)
    static let surfaceStrong = Color(red: 0.105, green: 0.122, blue: 0.148)
    static let controlStrong = Color(red: 0.145, green: 0.171, blue: 0.207)
    static let steelBlue = Color(red: 0.53, green: 0.62, blue: 0.72)
    static let line = steelBlue.opacity(0.22)
    static let lineStrong = steelBlue.opacity(0.38)

    static let violet = Color(red: 0.61, green: 0.23, blue: 1.00)
    static let indigo = Color(red: 0.32, green: 0.42, blue: 1.00)
    static let cyan = Color(red: 0.00, green: 0.82, blue: 1.00)

    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color(red: 0.70, green: 0.73, blue: 0.77)
    static let tertiaryText = Color(red: 0.49, green: 0.53, blue: 0.58)

    static let success = Color(red: 0.31, green: 0.91, blue: 0.69)
    static let warning = Color(red: 1.00, green: 0.68, blue: 0.29)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.48)
    /// High-contrast keyboard focus on graphite controls. White keeps focus
    /// distinct without introducing another decorative brand color.
    static let darkFocus = Color.white.opacity(0.96)

    static var spectrum: LinearGradient {
        LinearGradient(
            colors: [violet, indigo, cyan],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

}

/// The light, document-like workspace used by full app windows. Spectrum color
/// belongs to the live signal; the surrounding interface stays quiet and
/// readable.
enum FlowWorkspace {
    static let canvas = Color(red: 0.945, green: 0.950, blue: 0.957)
    static let surface = Color(red: 0.992, green: 0.993, blue: 0.995)
    static let surfaceRaised = Color(red: 0.918, green: 0.928, blue: 0.940)
    static let line = Color.black.opacity(0.11)
    static let lineStrong = Color(red: 0.20, green: 0.31, blue: 0.43).opacity(0.34)
    static let primaryText = Color(red: 0.070, green: 0.078, blue: 0.090)
    static let secondaryText = Color(red: 0.265, green: 0.285, blue: 0.320)
    static let tertiaryText = Color(red: 0.405, green: 0.430, blue: 0.470)
    static let action = Color(red: 0.105, green: 0.285, blue: 0.465)
    /// Semantic colors tuned for small status text on the light workspace.
    static let success = Color(red: 0.035, green: 0.365, blue: 0.255)
    static let danger = Color(red: 0.620, green: 0.105, blue: 0.175)
}

/// A neutral raised sheet with a fine machined edge and short contact shadow.
/// It provides depth without glass blur, colored glow, or decorative gradients.
struct FlowWorkspaceSurface: View {
    var radius: CGFloat = 16
    var emphasized = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(FlowWorkspace.surface)
            .overlay {
                shape.strokeBorder(
                    emphasized ? FlowWorkspace.lineStrong : FlowWorkspace.line,
                    lineWidth: emphasized ? 1 : 0.8
                )
            }
            .overlay {
                shape
                    .inset(by: 1)
                    .strokeBorder(Color.white.opacity(0.78), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.075), radius: 14, y: 5)
            .shadow(color: .black.opacity(0.055), radius: 2, y: 1)
    }
}

/// A static graphite light field used behind the product's primary signal
/// surfaces. Neutral lighting provides depth without decorative color or a
/// display-rate animation alongside audio capture.
struct FlowDepthBackdrop: View {
    var active = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    active ? FlowBrand.backgroundRaised : FlowBrand.background,
                    FlowBrand.background,
                    Color(red: 0.020, green: 0.026, blue: 0.036),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if !reduceTransparency {
                RadialGradient(
                    colors: [Color.white.opacity(active ? 0.10 : 0.065), .clear],
                    center: UnitPoint(x: 0.12, y: 0.04),
                    startRadius: 0,
                    endRadius: 260
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(active ? 0.025 : 0.015),
                        .clear,
                        Color.black.opacity(active ? 0.10 : 0.15),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

/// The primary dictation surface: dimensional graphite, a crisp inner edge,
/// and a physical contact shadow. Saturated color remains confined to the live
/// signal and its faint reflected light.
struct FlowInstrumentSurface: View {
    var active = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        shape
            .fill(FlowBrand.background)
            .overlay {
                FlowDepthBackdrop(active: active)
                    .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    active ? FlowBrand.lineStrong : Color.white.opacity(0.16),
                    lineWidth: 1
                )
            }
            .overlay {
                shape
                    .inset(by: 1.2)
                    .strokeBorder(Color.white.opacity(active ? 0.13 : 0.09), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }
}

/// Truthful, intentionally small representation of the complete dictation
/// path. These phases mirror the existing pipeline without introducing new
/// product state or touching the recording hot path.
enum FlowJourneyPhase: Equatable {
    case ready
    case listening
    case captured
    case onDevice
    case cursor
    case complete
}

enum FlowJourneyDestination {
    case cursor
    case notes
    case transcript
}

struct FlowPipelineRail: View {
    let phase: FlowJourneyPhase
    var destination: FlowJourneyDestination = .cursor
    var accessibilityStatus: String?

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    private enum Stage: Int, CaseIterable, Identifiable {
        case microphone
        case onDevice
        case cursor

        var id: Int { rawValue }

    }

    private enum StageState {
        case pending
        case active
        case complete
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Stage.allCases) { stage in
                stageView(stage)

                if stage != Stage.allCases.last {
                    Capsule(style: .continuous)
                        .fill(connectorStyle(after: stage))
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: differentiateWithoutColor && connectorIsReached(after: stage)
                                ? 3 : 1
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation path")
        .accessibilityValue(accessibilityValue)
    }

    private func stageView(_ stage: Stage) -> some View {
        let state = state(for: stage)
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(nodeStyle(for: state))
                Circle()
                    .strokeBorder(borderStyle(for: state), lineWidth: state == .active ? 1.2 : 0.7)
                if differentiateWithoutColor && state == .active {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.4)
                        .padding(-3)
                }
                Image(systemName: state == .complete ? "checkmark" : symbol(for: stage))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        state == .active ? FlowBrand.background : FlowBrand.primaryText)
            }
            .frame(width: 20, height: 20)

            Text(title(for: stage))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(labelColor(for: state))
                .fixedSize()
        }
    }

    private var activeIndex: Int {
        switch phase {
        case .ready: return -1
        case .listening: return Stage.microphone.rawValue
        case .captured: return -1
        case .onDevice: return Stage.onDevice.rawValue
        case .cursor: return Stage.cursor.rawValue
        case .complete: return Stage.allCases.count
        }
    }

    private func state(for stage: Stage) -> StageState {
        if phase == .captured {
            return stage == .microphone ? .complete : .pending
        }
        if phase == .complete || stage.rawValue < activeIndex { return .complete }
        if stage.rawValue == activeIndex { return .active }
        return .pending
    }

    private func title(for stage: Stage) -> String {
        switch stage {
        case .microphone: return "Mic"
        case .onDevice: return "On device"
        case .cursor:
            return destination == .notes
                ? "Notes" : destination == .transcript ? "Transcript" : "Cursor"
        }
    }

    private func symbol(for stage: Stage) -> String {
        switch stage {
        case .microphone: return "mic.fill"
        case .onDevice: return "cpu"
        case .cursor:
            return destination == .notes
                ? "note.text" : destination == .transcript ? "text.alignleft" : "cursorarrow"
        }
    }

    private func nodeStyle(for state: StageState) -> AnyShapeStyle {
        switch state {
        case .pending:
            return AnyShapeStyle(FlowBrand.surfaceStrong.opacity(0.78))
        case .active:
            return AnyShapeStyle(FlowBrand.spectrum)
        case .complete:
            return AnyShapeStyle(FlowBrand.controlStrong)
        }
    }

    private func borderStyle(for state: StageState) -> AnyShapeStyle {
        switch state {
        case .pending:
            return AnyShapeStyle(Color.white.opacity(0.14))
        case .active:
            return AnyShapeStyle(Color.white.opacity(0.72))
        case .complete:
            return AnyShapeStyle(FlowBrand.lineStrong)
        }
    }

    private func labelColor(for state: StageState) -> Color {
        switch state {
        case .pending: return FlowBrand.tertiaryText
        case .active: return FlowBrand.primaryText
        case .complete: return FlowBrand.secondaryText
        }
    }

    private func connectorStyle(after stage: Stage) -> AnyShapeStyle {
        connectorIsReached(after: stage)
            ? AnyShapeStyle(FlowBrand.steelBlue.opacity(0.62))
            : AnyShapeStyle(Color.white.opacity(0.11))
    }

    private func connectorIsReached(after stage: Stage) -> Bool {
        activeIndex > stage.rawValue
    }

    private var accessibilityValue: String {
        if let accessibilityStatus { return accessibilityStatus }
        switch phase {
        case .ready: return "Ready to listen"
        case .listening: return "Listening at the microphone"
        case .captured: return "Recording held in memory for this session"
        case .onDevice: return "Processing on this Mac"
        case .cursor:
            return destination == .notes
                ? "Saving meeting notes"
                : destination == .transcript
                    ? "Preparing in-app transcript" : "Placing text at the cursor"
        case .complete:
            return destination == .notes
                ? "Meeting saved in notes"
                : destination == .transcript
                    ? "Transcript ready in LockedIn Flow" : "Text delivered at the cursor"
        }
    }
}

/// A restrained physical response for the large instrument controls. Keyboard
/// focus is drawn by the containing deck so the full hit region remains clear.
struct FlowDeckButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.994 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// A compact text-action style with a full minimum target and an explicit
/// keyboard focus ring. It remains visually quiet until the user interacts,
/// so utility actions do not compete with the primary instrument.
struct FlowCompactButtonStyle: ButtonStyle {
    var focusColor = FlowBrand.darkFocus

    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .background(
                configuration.isPressed ? focusColor.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(focusColor, lineWidth: 1.5)
                }
            }
    }
}

/// The five-bar LockedIn Flow signal mark, drawn in SwiftUI so it remains crisp
/// from the tiny floating pill through the full Home window.
struct FlowSignalMark: View {
    private let relativeHeights: [CGFloat] = [0.42, 0.70, 1.0, 0.70, 0.42]

    var body: some View {
        GeometryReader { geometry in
            let gap = max(2, geometry.size.width * 0.055)
            let barWidth = max(
                2,
                (geometry.size.width - gap * CGFloat(relativeHeights.count - 1))
                    / CGFloat(relativeHeights.count)
            )

            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(relativeHeights.enumerated()), id: \.offset) { _, height in
                    Capsule(style: .continuous)
                        .frame(
                            width: barWidth, height: max(barWidth, geometry.size.height * height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(FlowBrand.spectrum)
        }
        .accessibilityHidden(true)
    }
}

struct FlowBrandTitle: View {
    var compact = false

    @ViewBuilder
    var body: some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("LOCKEDIN")
                    .foregroundStyle(FlowBrand.primaryText)
                Text("FLOW")
                    .foregroundStyle(FlowBrand.secondaryText)
            }
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(1.35)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LockedIn Flow")
        } else {
            Text("LockedIn Flow")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(FlowBrand.primaryText)
                .accessibilityLabel("LockedIn Flow")
        }
    }
}

struct FlowCardBackground: View {
    var radius: CGFloat = 16
    var emphasized = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                emphasized ? FlowBrand.surfaceStrong.opacity(0.94) : FlowBrand.surface.opacity(0.80)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        emphasized
                            ? AnyShapeStyle(FlowBrand.lineStrong)
                            : AnyShapeStyle(FlowBrand.line),
                        lineWidth: emphasized ? 1 : 0.7
                    )
            }
    }
}
