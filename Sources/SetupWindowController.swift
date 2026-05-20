import AppKit
import SwiftUI

@MainActor
final class SetupWindowController: NSWindowController {
    var onFinish: ((String, Set<DisplayStableID>, ModifierOption, Bool) -> Void)?

    private var hostingController: NSHostingController<SetupView>?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up DockPin"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(snapshot: DisplaySnapshot) {
        let view = SetupView(
            snapshot: snapshot,
            dockEdge: DockEdge.current(),
            onCancel: { [weak self] in
                self?.window?.close()
            }
        ) { [weak self] name, allowed, modifier, enableAfterSetup in
            self?.onFinish?(name, allowed, modifier, enableAfterSetup)
            self?.window?.close()
        }
        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        window?.contentViewController = hostingController

        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
