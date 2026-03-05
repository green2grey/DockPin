import AppKit
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var helpWindow: NSWindow?
    private var setupWindowController: SetupWindowController?
    private var autoSwitchTask: Task<Void, Never>?
    private var screenChangeTick = 0

    let monitor = DockMonitor()
    private let profileManager = ProfileManager()

    /// Sparkle updater controller. Starts automatic background checks on launch.
    let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        promptAccessibilityIfNeeded()
        handleV1ResetNoticeIfNeeded()

        applyCurrentState(snapshot: .current())

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

        let configured = isConfigured
        let active = profileManager.activeProfile

        let symbol: String
        let fallback: String
        let tooltip: String

        if !configured {
            symbol = "pin.slash"
            fallback = "lock.open"
            tooltip = "DockPin — Not configured"
        } else if active?.isEnabled == true {
            symbol = "pin.fill"
            fallback = "lock.fill"
            tooltip = "DockPin — \(active?.name ?? "Profile")"
        } else {
            symbol = "pin"
            fallback = "lock"
            tooltip = "DockPin — Disabled"
        }

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "DockPin")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "DockPin")
        img?.isTemplate = true
        button.image = img
        button.toolTip = tooltip
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

        let snapshot = DisplaySnapshot.current()
        let configured = isConfigured
        let active = profileManager.activeProfile

        // ── Header ──
        let hdrTitle: String = {
            guard configured, let active else { return "DockPin" }
            return "DockPin -- \(active.name)"
        }()
        let hdr = NSMenuItem(title: hdrTitle, action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        menu.addItem(hdr)

        menu.addItem(.separator())

        if !configured {
            let setup = NSMenuItem(title: "Set Up...", action: #selector(showSetup), keyEquivalent: "")
            setup.target = self
            if #available(macOS 14.0, *) {
                setup.badge = .newItems(count: 1)
            }
            menu.addItem(setup)
            menu.addItem(.separator())
        }

        // ── Enable / Disable ──
        let toggle = NSMenuItem(
            title: (active?.isEnabled == true) ? "Disable DockPin" : "Enable DockPin",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        toggle.keyEquivalentModifierMask = [.command]
        toggle.target = self
        toggle.isEnabled = configured && canEnableDockPin(activeProfile: active, snapshot: snapshot)
        if configured, NSScreen.screens.count < 2, active?.isEnabled != true {
            toggle.toolTip = "Requires two or more displays"
        } else if !configured {
            toggle.toolTip = "Set up DockPin first"
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
            mi.state = (active?.overrideModifier == mod) ? .on : .off
            modMenu.addItem(mi)
        }
        modItem.submenu = modMenu
        modItem.isEnabled = configured
        menu.addItem(modItem)

        menu.addItem(.separator())

        // ── Allow Dock on Display ──
        let allowItem = NSMenuItem(title: "Allow Dock on Display", action: nil, keyEquivalent: "")
        let allowMenu = NSMenu()
        let displays = snapshot.displays.filter { !$0.isMirroredSecondary }
        if displays.count < 2 {
            let note = NSMenuItem(title: "Connect a second display to use DockPin", action: nil, keyEquivalent: "")
            note.isEnabled = false
            allowMenu.addItem(note)
        }
        for d in displays {
            let mi = NSMenuItem(title: d.localizedName, action: #selector(toggleAllow(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = d.stableID
            mi.image = Self.displayIcon
            mi.state = (active?.allowedDisplays.contains(d.stableID) == true) ? .on : .off
            allowMenu.addItem(mi)
        }
        allowItem.submenu = allowMenu
        allowItem.isEnabled = configured
        menu.addItem(allowItem)

        menu.addItem(.separator())

        // ── Profiles ──
        let profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu()
        for p in profileManager.profiles {
            let mi = NSMenuItem(title: p.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.id
            mi.state = (p.id == profileManager.activeProfileID) ? .on : .off
            profilesMenu.addItem(mi)
        }
        if !profileManager.profiles.isEmpty {
            profilesMenu.addItem(.separator())
        }

        let autoSwitch = NSMenuItem(title: "Auto-switch Profiles", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoSwitch.target = self
        autoSwitch.state = profileManager.autoSwitchEnabled ? .on : .off
        profilesMenu.addItem(autoSwitch)

        if profileManager.manualHoldEnabled {
            let resume = NSMenuItem(title: "Resume Auto-switching", action: #selector(resumeAutoSwitching), keyEquivalent: "")
            resume.target = self
            profilesMenu.addItem(resume)
        }

        profilesMenu.addItem(.separator())

        let saveCurrent = NSMenuItem(title: "Save Current as Profile...", action: #selector(saveCurrentAsProfile), keyEquivalent: "")
        saveCurrent.target = self
        profilesMenu.addItem(saveCurrent)

        profilesItem.submenu = profilesMenu
        profilesItem.isEnabled = configured && (active != nil)
        menu.addItem(profilesItem)

        menu.addItem(.separator())

        // ── Check for Updates ──
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)

        // ── Help ──
        let help = NSMenuItem(title: "Help...", action: #selector(showHelp), keyEquivalent: "?")
        help.keyEquivalentModifierMask = [.command]
        help.target = self
        menu.addItem(help)

        // ── Launch at Startup ──
        let startup = NSMenuItem(title: "Launch at Startup", action: #selector(toggleStartup), keyEquivalent: "")
        startup.target = self
        startup.state = isLoginItemEnabled ? .on : .off
        menu.addItem(startup)

        menu.addItem(.separator())

        // ── Quit ──
        let quit = NSMenuItem(title: "Quit DockPin", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Help content

    private static let helpContent: NSAttributedString = {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bodyColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.paragraphSpacing = 8

        let headingPara = NSMutableParagraphStyle()
        headingPara.paragraphSpacingBefore = 16
        headingPara.paragraphSpacing = 6

        func title(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: titleFont,
                .foregroundColor: bodyColor
            ]))
        }

        func heading(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: headingFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: headingPara
            ]))
        }

        func body(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyPara
            ]))
        }

        func bullet(_ text: String) {
            result.append(NSAttributedString(string: "• " + text + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyPara
            ]))
        }

        func numbered(_ num: Int, _ text: String) {
            result.append(NSAttributedString(string: "\(num). " + text + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyPara
            ]))
        }

        title("DockPin")
        body("Keep your Dock exactly where you want it.")

        heading("Getting Started")
        numbered(1, "Grant Accessibility permission when prompted (System Settings → Privacy & Security → Accessibility). Relaunch the app after granting access.")
        numbered(2, "Click DockPin in the menu bar.")
        numbered(3, "Choose Set Up…, name your first profile, and select the displays where the Dock is allowed.")
        numbered(4, "Optionally enable DockPin after setup, or enable it later from the menu.")

        heading("Profiles")
        body("Profiles store:")
        bullet("Which displays can host the Dock")
        bullet("Your override modifier key")
        bullet("Whether DockPin is enabled")
        body("Switch profiles from the Profiles submenu. Selecting a profile temporarily pauses auto-switching until you choose Resume Auto-switching.")

        heading("Auto-switching")
        body("If auto-switching is enabled, DockPin can switch profiles based on display configurations. If multiple profiles match equally, DockPin won't switch automatically.")

        heading("Override Modifier Key")
        body("Hold a modifier key (Option by default) to temporarily bypass locking and move the Dock freely. You can change the key per profile under Override Modifier Key.")

        heading("Launch at Startup")
        body("Toggle Launch at Startup so DockPin runs automatically when you log in.")

        heading("Requirements")
        bullet("macOS 13 or later")
        bullet("Two or more connected displays")
        bullet("Dock positioned at the bottom of the screen")
        bullet("\"Displays have separate Spaces\" enabled (System Settings → Desktop & Dock)")

        return result
    }()

    private static let displayIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }()

    // MARK: - Actions

    @objc private func toggleEnabled() {
        guard isConfigured, let active = profileManager.activeProfile else { return }

        if active.isEnabled {
            profileManager.updateProfile(id: active.id) { $0.isEnabled = false }
        } else {
            if active.allowedDisplays.isEmpty {
                showNeedsAllowedDisplayAlert()
                return
            }
            profileManager.updateProfile(id: active.id) { $0.isEnabled = true }
        }

        applyCurrentState(snapshot: .current())
        updateIcon()
    }

    @objc private func toggleAllow(_ sender: NSMenuItem) {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        guard let stableID = sender.representedObject as? DisplayStableID else { return }

        if active.allowedDisplays.contains(stableID) {
            if active.allowedDisplays.count <= 1 {
                showNeedsAllowedDisplayAlert()
                return
            }
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.remove(stableID) }
        } else {
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.insert(stableID) }
        }

        applyCurrentState(snapshot: .current())
    }

    @objc private func pickModifier(_ sender: NSMenuItem) {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        let opt = ModifierOption(rawValue: sender.tag) ?? .option
        profileManager.updateProfile(id: active.id) { $0.overrideModifier = opt }
        applyCurrentState(snapshot: .current())
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

    @objc private func showSetup() {
        openSetupWindow()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        profileManager.setActiveProfile(id: id, manualHold: true)
        applyCurrentState(snapshot: .current())
    }

    @objc private func toggleAutoSwitch() {
        profileManager.autoSwitchEnabled.toggle()
        if profileManager.autoSwitchEnabled {
            scheduleAutoSwitch()
        }
    }

    @objc private func resumeAutoSwitching() {
        profileManager.manualHoldEnabled = false
        scheduleAutoSwitch()
    }

    @objc private func saveCurrentAsProfile() {
        guard isConfigured else { return }

        let alert = NSAlert()
        alert.messageText = "Save Current Settings as Profile"
        alert.informativeText = "Enter a name for the new profile."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "Profile Name"
        nameField.stringValue = "New Profile"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        _ = profileManager.saveCurrentAsProfile(name: name)
        applyCurrentState(snapshot: .current())
    }

    @objc private func quitApp() {
        monitor.stopLocking()
        NSApp.terminate(nil)
    }

    @objc private func screensChanged() {
        applyCurrentState(snapshot: .current())
        scheduleAutoSwitch()
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

// MARK: - App state helpers

extension AppDelegate {
    private var isConfigured: Bool {
        profileManager.setupCompleted && !profileManager.profiles.isEmpty
    }

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func canEnableDockPin(activeProfile: DockProfile?, snapshot: DisplaySnapshot) -> Bool {
        if !isConfigured { return false }
        if NSScreen.screens.count < 2 && activeProfile?.isEnabled != true { return false }
        if activeProfile?.isEnabled == true { return true }
        return true
    }

    private func applyCurrentState(snapshot: DisplaySnapshot) {
        guard isConfigured else {
            monitor.stopLocking()
            monitor.allowedDisplays.removeAll()
            updateIcon()
            return
        }

        if profileManager.activeProfileID == nil, let first = profileManager.profiles.first {
            profileManager.setActiveProfile(id: first.id, manualHold: false)
        }
        guard let active = profileManager.activeProfile else { return }

        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)
        monitor.allowedDisplays = resolvedAllowed
        monitor.overrideModifier = active.overrideModifier

        if active.isEnabled, isAccessibilityTrusted(), !resolvedAllowed.isEmpty {
            if !monitor.startLocking() {
                promptAccessibilityIfNeeded()
            }
        } else {
            monitor.stopLocking()
        }

        if monitor.isEnabled {
            monitor.refreshScreenCache()
        }

        updateIcon()
    }

    private func v1KeysPresent() -> Bool {
        let d = UserDefaults.standard
        let hasAllowed = (d.array(forKey: "allowedDisplays") as? [Int])?.isEmpty == false
        let hasEnabled = d.object(forKey: "isEnabled") != nil
        let hasOverride = d.object(forKey: "overrideModifier") != nil
        return hasAllowed || hasEnabled || hasOverride
    }

    private func handleV1ResetNoticeIfNeeded() {
        guard v1KeysPresent(), !profileManager.resetNoticeShown else { return }

        let alert = NSAlert()
        alert.messageText = "DockPin Has Been Updated"
        alert.informativeText = "This update resets previous settings. Please set up DockPin again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up Now")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()

        profileManager.resetNoticeShown = true

        let d = UserDefaults.standard
        d.removeObject(forKey: "allowedDisplays")
        d.removeObject(forKey: "isEnabled")
        d.removeObject(forKey: "overrideModifier")

        monitor.stopLocking()
        monitor.allowedDisplays.removeAll()

        if response == .alertFirstButtonReturn {
            openSetupWindow()
        }
    }

    private func openSetupWindow() {
        if setupWindowController == nil {
            setupWindowController = SetupWindowController()
        }

        setupWindowController?.onFinish = { [weak self] name, allowed, overrideModifier, enableAfterSetup in
            guard let self else { return }
            let profile = DockProfile(
                name: name,
                isEnabled: enableAfterSetup,
                overrideModifier: overrideModifier,
                allowedDisplays: allowed
            )
            self.profileManager.addProfile(profile, makeActive: true)
            self.profileManager.setupCompleted = true
            self.profileManager.manualHoldEnabled = false
            self.applyCurrentState(snapshot: .current())
        }

        setupWindowController?.present(snapshot: .current())
    }

    private func showNeedsAllowedDisplayAlert() {
        let alert = NSAlert()
        alert.messageText = "At least one display must be allowed."
        alert.informativeText = "The Dock needs somewhere to live. Allow another display first before removing this one."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func scheduleAutoSwitch() {
        guard isConfigured else { return }
        guard profileManager.setupCompleted, profileManager.autoSwitchEnabled, !profileManager.manualHoldEnabled else { return }

        screenChangeTick += 1
        let startedTick = screenChangeTick

        if autoSwitchTask != nil { return }

        autoSwitchTask = Task { [weak self] in
            guard let self else { return }

            let debounceInterval = Duration.milliseconds(600)
            let maxWaitInterval = Duration.seconds(3)
            var waited: Duration = .zero
            var lastObservedTick = startedTick

            while true {
                try? await Task.sleep(for: debounceInterval, clock: .suspending)
                if Task.isCancelled { return }

                let currentTick = await MainActor.run { self.screenChangeTick }
                if currentTick == lastObservedTick { break }

                lastObservedTick = currentTick
                waited += debounceInterval
                if waited >= maxWaitInterval { break }
            }

            await MainActor.run {
                self.performAutoSwitchIfNeeded(snapshot: .current())
                self.autoSwitchTask = nil
            }
        }
    }

    private func performAutoSwitchIfNeeded(snapshot: DisplaySnapshot) {
        guard let match = profileManager.bestAutoSwitchMatch(snapshot: snapshot) else { return }
        guard match.id != profileManager.activeProfileID else { return }
        profileManager.setActiveProfile(id: match.id, manualHold: false)
        applyCurrentState(snapshot: snapshot)
    }
}
