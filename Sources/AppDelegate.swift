import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var helpWindow: NSWindow?
    let monitor = DockMonitor()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // System will show its own accessibility prompt if needed
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        monitor.restoreState()

        if trusted && monitor.isEnabled {
            monitor.startLocking()
        }

        updateIcon()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem.menu = buildMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = monitor.isEnabled ? "lock.fill" : "lock.open"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "DockPin") {
            img.isTemplate = true
            button.image = img
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    /// Rebuild the full menu contents (called each time the menu opens via delegate).
    fileprivate func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // ── Header ──
        let hdr = NSMenuItem(title: "DockPin v1.0", action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        menu.addItem(hdr)

        menu.addItem(.separator())

        // ── Launch at Startup ──
        let startup = NSMenuItem(title: "Launch at Startup", action: #selector(toggleStartup), keyEquivalent: "")
        startup.target = self
        startup.state = isLoginItemEnabled ? .on : .off
        menu.addItem(startup)

        menu.addItem(.separator())

        // ── Enable / Disable ──
        let toggle = NSMenuItem(
            title: monitor.isEnabled ? "Disable DockPin" : "Enable DockPin",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        toggle.keyEquivalentModifierMask = [.command]
        toggle.target = self
        if NSScreen.screens.count < 2 && !monitor.isEnabled {
            toggle.isEnabled = false
            toggle.toolTip = "Requires two or more displays"
        }
        menu.addItem(toggle)

        menu.addItem(.separator())

        // ── Override modifier key ──
        let modItem = NSMenuItem(title: "Override Modifier Key", action: nil, keyEquivalent: "")
        let modMenu = NSMenu()
        for mod in ModifierOption.allCases {
            let mi = NSMenuItem(title: mod.label, action: #selector(pickModifier(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = mod.rawValue
            mi.state = monitor.overrideModifier == mod ? .on : .off
            modMenu.addItem(mi)
        }
        modItem.submenu = modMenu
        menu.addItem(modItem)

        menu.addItem(.separator())

        // ── Allow Dock on Display ──
        let allowItem = NSMenuItem(title: "Allow Dock on Display", action: nil, keyEquivalent: "")
        let allowMenu = NSMenu()
        let screens = NSScreen.screens
        if screens.count < 2 {
            let note = NSMenuItem(title: "Connect a second display to use DockPin", action: nil, keyEquivalent: "")
            note.isEnabled = false
            allowMenu.addItem(note)
        }
        for screen in screens {
            let mi = NSMenuItem(title: screen.localizedName, action: #selector(toggleAllow(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Int(screen.displayID)
            mi.image = Self.displayIcon
            mi.state = monitor.allowedDisplays.contains(screen.displayID) ? .on : .off
            allowMenu.addItem(mi)
        }
        allowItem.submenu = allowMenu
        menu.addItem(allowItem)

        menu.addItem(.separator())

        // ── Help ──
        let help = NSMenuItem(title: "Help...", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        menu.addItem(help)

        menu.addItem(.separator())

        // ── Quit ──
        let quit = NSMenuItem(title: "Quit DockPin", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Help content

    private static let helpContent: NSAttributedString = {
        let body   = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bold   = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let heading = NSFont.systemFont(ofSize: 15, weight: .bold)
        let title  = NSFont.systemFont(ofSize: 20, weight: .bold)
        let small  = NSFont.systemFont(ofSize: 12, weight: .regular)

        let bodyColor = NSColor.labelColor
        let dimColor  = NSColor.secondaryLabelColor

        let result = NSMutableAttributedString()

        func addTitle(_ text: String) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = 0
            para.paragraphSpacing = 4
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: title, .foregroundColor: bodyColor, .paragraphStyle: para
            ]))
        }

        func addHeading(_ text: String) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = 18
            para.paragraphSpacing = 6
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: heading, .foregroundColor: bodyColor, .paragraphStyle: para
            ]))
        }

        func addBody(_ text: String, indent: CGFloat = 0) {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 3
            para.paragraphSpacing = 8
            para.headIndent = indent
            para.firstLineHeadIndent = indent
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: body, .foregroundColor: bodyColor, .paragraphStyle: para
            ]))
        }

        func addStep(_ number: String, _ text: String) {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 3
            para.paragraphSpacing = 10
            para.headIndent = 28
            para.firstLineHeadIndent = 0
            para.tabStops = [NSTextTab(textAlignment: .left, location: 28)]

            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: number + "\t", attributes: [
                .font: bold, .foregroundColor: dimColor, .paragraphStyle: para
            ]))
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: body, .foregroundColor: bodyColor, .paragraphStyle: para
            ]))
            result.append(s)
        }

        func addBullet(_ text: String) {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.paragraphSpacing = 4
            para.headIndent = 20
            para.firstLineHeadIndent = 0
            para.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
            result.append(NSAttributedString(string: "\u{2022}\t" + text + "\n", attributes: [
                .font: small, .foregroundColor: dimColor, .paragraphStyle: para
            ]))
        }

        // ── Build content ──

        addTitle("DockPin")

        let tagline = NSMutableParagraphStyle()
        tagline.paragraphSpacing = 12
        result.append(NSAttributedString(string: "Keep your Dock exactly where you want it.\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: dimColor,
            .paragraphStyle: tagline
        ]))

        addHeading("Getting Started")
        addStep("1.", "Grant Accessibility permission when prompted (System Settings \u{2192} Privacy & Security \u{2192} Accessibility). Relaunch the app after granting access.")
        addStep("2.", "Click the lock icon in the menu bar.")
        addStep("3.", "Open Allow Dock on Display and check the screen(s) where the Dock is allowed.")
        addStep("4.", "Click Enable DockPin. The icon changes to a filled lock when active.")

        addHeading("Override Modifier Key")
        addBody("Hold a modifier key (Option by default) to temporarily bypass locking and move the Dock freely. You can change the key under Override Modifier Key.")

        addHeading("Allow / Disallow Displays")
        addBody("Check or uncheck screens under Allow Dock on Display. The Dock will only appear on checked screens. At least one must stay checked.")

        addHeading("Launch at Startup")
        addBody("Toggle Launch at Startup so DockPin runs automatically when you log in. Your selections and lock state are remembered across sessions.")

        addHeading("Requirements")
        addBullet("macOS 13 or later")
        addBullet("Two or more connected displays")
        addBullet("Dock positioned at the bottom of the screen")
        addBullet("\"Displays have separate Spaces\" enabled (System Settings \u{2192} Desktop & Dock)")

        return result
    }()

    private static let displayIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }()

    // MARK: - Actions

    @objc private func toggleEnabled() {
        if monitor.isEnabled {
            monitor.stopLocking()
        } else {
            if monitor.allowedDisplays.isEmpty {
                if let screen = DockMonitor.currentDockScreen() {
                    monitor.allowedDisplays.insert(screen.displayID)
                }
            }
            if !monitor.startLocking() {
                // Event tap failed — most likely missing Accessibility permission
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                return
            }
        }
        monitor.saveState()
        updateIcon()
    }

    @objc private func toggleAllow(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        if monitor.allowedDisplays.contains(id) {
            if monitor.allowedDisplays.count <= 1 {
                let alert = NSAlert()
                alert.messageText = "At least one display must be allowed."
                alert.informativeText = "The Dock needs somewhere to live. Allow another display first before removing this one."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            monitor.allowedDisplays.remove(id)
        } else {
            monitor.allowedDisplays.insert(id)
        }
        monitor.saveState()
        if monitor.isEnabled { monitor.refreshScreenCache() }
    }

    @objc private func pickModifier(_ sender: NSMenuItem) {
        monitor.overrideModifier = ModifierOption(rawValue: sender.tag) ?? .option
        monitor.saveState()
    }

    @objc private func toggleStartup() {
        if isLoginItemEnabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func showHelp() {
        if let w = helpWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "DockPin Help"
        w.center()
        w.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let tv = NSTextView(frame: scroll.contentView.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isSelectable = true
        tv.textContainerInset = NSSize(width: 24, height: 24)
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0

        tv.textStorage?.setAttributedString(Self.helpContent)

        scroll.documentView = tv
        w.contentView = scroll
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        helpWindow = w
    }

    @objc private func quitApp() {
        monitor.stopLocking()
        NSApp.terminate(nil)
    }

    @objc private func screensChanged() {
        let currentIDs = Set(NSScreen.screens.map { $0.displayID })
        monitor.allowedDisplays = monitor.allowedDisplays.intersection(currentIDs)
        if monitor.isEnabled { monitor.refreshScreenCache() }
        monitor.saveState()
        updateIcon()
    }

    // MARK: - Helpers

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

}

// MARK: - NSMenuDelegate – rebuild items each time the menu opens

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        populateMenu(menu)
    }
}

// MARK: - NSScreen helper

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }
}
