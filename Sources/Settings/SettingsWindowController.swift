import AppKit
import SwiftUI

/// Owns the settings window. The window is created the first time it's asked for and kept
/// afterwards, so it reopens where the user left it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    /// Called when the window is shown or closed.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Called when the user comes back to the window, for example from System Settings, where
    /// they may have just changed something this window reports.
    var onBecomeKey: (() -> Void)?

    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show(pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }

        let window = self.window ?? makeWindow()
        self.window = window

        // A menu bar app is never frontmost by itself; without this the window opens behind
        // whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?()
    }

    private func makeWindow() -> NSWindow {
        let window = Self.makeWindow(model: model)
        window.delegate = self
        window.center()
        return window
    }

    /// Builds the window without showing it.
    static func makeWindow(model: SettingsModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DockPin Settings"
        // The content runs to the top edge, with the close button over the sidebar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        // With a full-size content view the content is as tall as the whole frame.
        window.setFrame(NSRect(origin: window.frame.origin, size: SettingsView.size), display: false)
        return window
    }
}
