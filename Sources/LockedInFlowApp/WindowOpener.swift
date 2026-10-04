import AppKit
import SwiftUI

/// Opens and retains standalone windows (history, onboarding) for the menu-bar app.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()

    private var windows: [String: NSWindow] = [:]

    private init() {}

    func showHistory(state: AppState) {
        show(
            key: "history",
            title: "Dictation History",
            size: NSSize(width: 700, height: 560),
            minSize: NSSize(width: 660, height: 500),
            resizable: true
        ) {
            HistoryView().environmentObject(state)
        }
    }

    func showHome(state: AppState) {
        show(
            key: "home",
            title: "LockedIn Flow",
            size: NSSize(width: 620, height: 680),
            minSize: NSSize(width: 600, height: 630),
            resizable: true
        ) {
            HomeView().environmentObject(state)
        }
    }

    func showOnboarding(state: AppState) {
        show(
            key: "onboarding", title: "Welcome to LockedIn Flow",
            size: NSSize(width: 560, height: 500),
            minSize: NSSize(width: 520, height: 480),
            resizable: true
        ) {
            OnboardingView().environmentObject(state)
        }
    }

    func closeOnboarding() {
        windows.removeValue(forKey: "onboarding")?.close()
    }

    func showModelSetup(state: AppState) {
        show(
            key: "model-setup", title: "LockedIn Flow — Speech Models",
            size: NSSize(width: 600, height: 660),
            minSize: NSSize(width: 520, height: 480),
            resizable: true
        ) {
            ModelSetupView().environmentObject(state)
        }
    }

    func closeModelSetup() {
        windows["model-setup"]?.close()
    }

    func showMeetings(state: AppState) {
        show(key: "meetings", title: "Meeting Notes", size: NSSize(width: 640, height: 460)) {
            MeetingsView().environmentObject(state)
        }
    }

    func showCompare(state: AppState) {
        show(key: "compare", title: "Raw vs Final", size: NSSize(width: 540, height: 300)) {
            CompareView().environmentObject(state)
        }
    }

    private func show<Content: View>(
        key: String,
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        resizable: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { styleMask.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        if let minSize { window.minSize = minSize }
        window.contentView = NSHostingView(rootView: content())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[key] = window
    }
}
