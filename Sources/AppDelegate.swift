import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusBarModel = StatusBarModel()
    private lazy var statusPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 600)
        popover.contentViewController = NSHostingController(
            rootView: DockPinPopoverView(model: statusBarModel, actions: self)
        )
        return popover
    }()
    private var helpWindow: NSWindow?
    private var setupWindowController: SetupWindowController?
    private var autoSwitchTask: Task<Void, Never>?
    private var screenChangeTick = 0

    let monitor = DockMonitor()
    private let dockReanchorer = DockReanchorer()
    private let profileManager = ProfileManager()

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
        monitor.onDockEdgeChanged = { [weak self] in
            self?.applyCurrentState(snapshot: .current())
        }

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

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        dockReanchorer.cancel()
        monitor.stopLocking()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        button.setAccessibilityLabel(tooltip)
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        refreshStatusBarModel(snapshot: .current())
        if statusPopover.isShown {
            statusPopover.performClose(sender)
        } else {
            statusPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closeStatusPopover() {
        if statusPopover.isShown {
            statusPopover.performClose(nil)
        }
    }

    // MARK: - Help content

    private static let helpContent: NSAttributedString = {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bodyColor = NSColor.labelColor

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

        heading("Dock Edge")
        body("DockPin follows the current macOS Dock edge setting (Left, Bottom, or Right). If another display fully covers the chosen edge, macOS won’t place the Dock there. DockPin warns when your current arrangement blocks that edge.")

        heading("Re-anchor Dock Now")
        body("macOS does not provide any way for apps to move the Dock to a specific display. When you select Re-anchor Dock Now, DockPin briefly moves the cursor to the chosen display’s edge and back to simulate the gesture macOS uses to relocate the Dock. This is best-effort — it may not work in every situation.")
        body("Re-anchor is available when exactly one display is allowed and its current Dock edge is exposed. DockPin also attempts a re-anchor automatically when you enable locking, switch profiles, or displays change.")

        heading("Override Modifier Key")
        body("Hold a modifier key (Option by default) to temporarily bypass locking and move the Dock freely. You can change the key per profile under Override Modifier Key.")

        heading("Launch at Startup")
        body("Toggle Launch at Startup so DockPin runs automatically when you log in.")

        heading("Requirements")
        bullet("macOS 13 or later")
        bullet("Two or more connected displays")
        bullet("Dock positioned on the Left, Bottom, or Right edge")
        bullet("\"Displays have separate Spaces\" enabled (System Settings → Desktop & Dock)")

        return result
    }()

    // MARK: - Actions

    @objc private func toggleEnabled() {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        let snapshot = DisplaySnapshot.current()
        let dockEdge = DockEdge.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: dockEdge,
            mirroringPolicy: active.mirroringPolicy
        )
        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)

        if active.isEnabled {
            profileManager.updateProfile(id: active.id) { $0.isEnabled = false }
        } else {
            if resolvedAllowed.isEmpty {
                showNeedsAllowedDisplayAlert()
                return
            }
            if reachableAllowedDisplayIDs(resolvedAllowed: resolvedAllowed, reachability: reachability).isEmpty {
                showBlockedDockEdgeAlert(
                    dockEdge: dockEdge,
                    blockedDisplays: blockedAllowedDisplayNames(
                        resolvedAllowed: resolvedAllowed,
                        snapshot: snapshot,
                        mirroringPolicy: active.mirroringPolicy,
                        reachability: reachability
                    )
                )
                return
            }
            profileManager.updateProfile(id: active.id) { $0.isEnabled = true }
        }

        applyCurrentState(snapshot: snapshot, attemptReanchor: true)
        updateIcon()
    }

    private func toggleAllowedDisplay(_ stableID: DisplayStableID) {
        guard isConfigured, let active = profileManager.activeProfile else { return }

        if active.allowedDisplays.contains(stableID) {
            if active.allowedDisplays.count <= 1 {
                showNeedsAllowedDisplayAlert()
                return
            }
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.remove(stableID) }
        } else {
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.insert(stableID) }
        }

        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    private func setOverrideModifier(_ opt: ModifierOption) {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        profileManager.updateProfile(id: active.id) { $0.overrideModifier = opt }
        applyCurrentState(snapshot: .current())
    }

    private func toggleStartup() {
        if isLoginItemEnabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        refreshStatusBarModel(snapshot: .current())
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

    private func showSetup() {
        openSetupWindow()
    }

    private func selectProfile(id: UUID) {
        profileManager.setActiveProfile(id: id, manualHold: true)
        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    private func toggleAutoSwitch() {
        profileManager.autoSwitchEnabled.toggle()
        if profileManager.autoSwitchEnabled {
            scheduleAutoSwitch()
        }
        refreshStatusBarModel(snapshot: .current())
    }

    private func resumeAutoSwitching() {
        profileManager.manualHoldEnabled = false
        scheduleAutoSwitch()
        refreshStatusBarModel(snapshot: .current())
    }

    private func saveCurrentAsProfile() {
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
        dockReanchorer.cancel()
        monitor.stopLocking()
        NSApp.terminate(nil)
    }

    @objc private func screensChanged() {
        applyCurrentState(snapshot: .current(), attemptReanchor: true)
        scheduleAutoSwitch()
    }

    private func reanchorDockNow() {
        guard let active = profileManager.activeProfile else { return }
        let snapshot = DisplaySnapshot.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: DockEdge.current(),
            mirroringPolicy: active.mirroringPolicy
        )
        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)
        guard let target = reanchorPlan(activeProfile: active, resolvedAllowed: resolvedAllowed, reachability: reachability).target else { return }
        dockReanchorer.reanchor(to: target)
    }

    // MARK: - Helpers

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

}

// MARK: - StatusBarActions

extension AppDelegate: StatusBarActions {
    func statusBarToggleEnabled() {
        toggleEnabled()
    }

    func statusBarToggleAllowedDisplay(_ stableID: DisplayStableID) {
        toggleAllowedDisplay(stableID)
    }

    func statusBarSetOverrideModifier(_ modifier: ModifierOption) {
        setOverrideModifier(modifier)
    }

    func statusBarSelectProfile(_ id: UUID) {
        selectProfile(id: id)
    }

    func statusBarToggleAutoSwitch() {
        toggleAutoSwitch()
    }

    func statusBarResumeAutoSwitching() {
        resumeAutoSwitching()
    }

    func statusBarSaveCurrentAsProfile() {
        saveCurrentAsProfile()
    }

    func statusBarReanchorDockNow() {
        reanchorDockNow()
    }

    func statusBarShowSetup() {
        closeStatusPopover()
        showSetup()
    }

    func statusBarShowHelp() {
        closeStatusPopover()
        showHelp()
    }

    func statusBarCheckForUpdates() {
        closeStatusPopover()
        updaterController.checkForUpdates(nil)
    }

    func statusBarToggleStartup() {
        toggleStartup()
    }

    func statusBarQuit() {
        quitApp()
    }
}

// MARK: - App state helpers

extension AppDelegate {
    private struct ReanchorPlan {
        var target: DisplayEdgeReachability?
        var disabledReason: String?
    }

    private var isConfigured: Bool {
        profileManager.setupCompleted && !profileManager.profiles.isEmpty
    }

    private func refreshStatusBarModel(snapshot: DisplaySnapshot) {
        let active = profileManager.activeProfile
        let dockEdge = DockEdge.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: dockEdge,
            mirroringPolicy: active?.mirroringPolicy ?? .ignoreMirroredSecondaries
        )
        let resolvedAllowed = active.map {
            profileManager.resolveAllowedDisplayIDs(for: $0, snapshot: snapshot)
        } ?? []
        let reanchor = reanchorPlan(
            activeProfile: active,
            resolvedAllowed: resolvedAllowed,
            reachability: reachability
        )
        let blockedSummary = active.flatMap {
            blockedSelectionSummary(
                resolvedAllowed: resolvedAllowed,
                snapshot: snapshot,
                mirroringPolicy: $0.mirroringPolicy,
                dockEdge: dockEdge,
                reachability: reachability
            )
        }

        statusBarModel.update(
            StatusBarState(
                displaySnapshot: snapshot,
                profiles: profileManager.profiles,
                activeProfileID: profileManager.activeProfileID,
                activeProfile: active,
                dockEdge: dockEdge,
                reachability: reachability,
                resolvedAllowedDisplayIDs: resolvedAllowed,
                isConfigured: isConfigured,
                isAccessibilityTrusted: isAccessibilityTrusted(),
                isLoginItemEnabled: isLoginItemEnabled,
                autoSwitchEnabled: profileManager.autoSwitchEnabled,
                manualHoldEnabled: profileManager.manualHoldEnabled,
                toggleDisabledReason: toggleEnableDisabledReason(
                    activeProfile: active,
                    resolvedAllowed: resolvedAllowed,
                    dockEdge: dockEdge,
                    reachability: reachability
                ),
                reanchorDisabledReason: reanchor.disabledReason,
                blockedSelectionSummary: blockedSummary
            )
        )
    }

    private func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func toggleEnableDisabledReason(
        activeProfile: DockProfile?,
        resolvedAllowed: Set<CGDirectDisplayID>,
        dockEdge: DockEdge,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> String? {
        guard isConfigured else { return "Set up DockPin first" }
        if activeProfile?.isEnabled == true { return nil }
        if NSScreen.screens.count < 2 { return "Requires two or more displays" }
        guard activeProfile != nil else { return "Select a profile first" }
        if resolvedAllowed.isEmpty { return "Allow at least one display first" }
        if reachableAllowedDisplayIDs(resolvedAllowed: resolvedAllowed, reachability: reachability).isEmpty {
            return "No allowed display currently exposes the \(dockEdge.requirementDescription)"
        }
        return nil
    }

    private func reachableAllowedDisplayIDs(
        resolvedAllowed: Set<CGDirectDisplayID>,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> Set<CGDirectDisplayID> {
        Set(resolvedAllowed.filter { reachability[$0]?.isReachable == true })
    }

    private func blockedAllowedDisplayNames(
        resolvedAllowed: Set<CGDirectDisplayID>,
        snapshot: DisplaySnapshot,
        mirroringPolicy: MirroringPolicy,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> [String] {
        snapshot.filtered(for: mirroringPolicy)
            .filter { resolvedAllowed.contains($0.displayID) }
            .filter { !(reachability[$0.displayID]?.isReachable ?? false) }
            .map(\.localizedName)
    }

    private func blockedSelectionSummary(
        resolvedAllowed: Set<CGDirectDisplayID>,
        snapshot: DisplaySnapshot,
        mirroringPolicy: MirroringPolicy,
        dockEdge: DockEdge,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> String? {
        let names = blockedAllowedDisplayNames(
            resolvedAllowed: resolvedAllowed,
            snapshot: snapshot,
            mirroringPolicy: mirroringPolicy,
            reachability: reachability
        )
        guard !names.isEmpty else { return nil }

        let summary = names.prefix(2).joined(separator: ", ")
        if names.count > 2 {
            return "\(dockEdge.label) edge blocked on: \(summary), +\(names.count - 2) more"
        }
        return "\(dockEdge.label) edge blocked on: \(summary)"
    }

    private func reanchorPlan(
        activeProfile: DockProfile?,
        resolvedAllowed: Set<CGDirectDisplayID>,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> ReanchorPlan {
        guard let activeProfile else {
            return ReanchorPlan(target: nil, disabledReason: "Select a profile first")
        }
        guard activeProfile.isEnabled else {
            return ReanchorPlan(target: nil, disabledReason: "Enable DockPin first")
        }
        guard !resolvedAllowed.isEmpty else {
            return ReanchorPlan(target: nil, disabledReason: "Allow at least one display first")
        }
        guard resolvedAllowed.count == 1, let displayID = resolvedAllowed.first else {
            return ReanchorPlan(target: nil, disabledReason: "Re-anchor requires exactly one current allowed display")
        }

        guard let target = reachability[displayID] else {
            return ReanchorPlan(target: nil, disabledReason: "Selected display is not currently available")
        }
        guard target.isReachable else {
            return ReanchorPlan(target: nil, disabledReason: target.blockedReason)
        }

        return ReanchorPlan(target: target, disabledReason: nil)
    }

    private func applyCurrentState(snapshot: DisplaySnapshot, attemptReanchor: Bool = false) {
        guard isConfigured else {
            dockReanchorer.cancel()
            monitor.stopLocking()
            monitor.allowedDisplays.removeAll()
            refreshStatusBarModel(snapshot: snapshot)
            updateIcon()
            return
        }

        if profileManager.activeProfileID == nil, let first = profileManager.profiles.first {
            profileManager.setActiveProfile(id: first.id, manualHold: false)
        }
        guard let active = profileManager.activeProfile else { return }

        let dockEdge = DockEdge.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: dockEdge,
            mirroringPolicy: active.mirroringPolicy
        )
        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)
        let reachableAllowed = reachableAllowedDisplayIDs(resolvedAllowed: resolvedAllowed, reachability: reachability)
        monitor.allowedDisplays = resolvedAllowed
        monitor.overrideModifier = active.overrideModifier

        if active.isEnabled, isAccessibilityTrusted(), !reachableAllowed.isEmpty {
            if !monitor.startLocking() {
                promptAccessibilityIfNeeded()
            }
        } else {
            dockReanchorer.cancel()
            monitor.stopLocking()
        }

        if monitor.isEnabled {
            monitor.refreshScreenCache()
        }

        if attemptReanchor, active.isEnabled, monitor.isEnabled {
            if let target = reanchorPlan(activeProfile: active, resolvedAllowed: resolvedAllowed, reachability: reachability).target {
                dockReanchorer.reanchor(to: target)
            } else {
                dockReanchorer.cancel()
            }
        }

        updateIcon()
        refreshStatusBarModel(snapshot: snapshot)
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

        dockReanchorer.cancel()
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
            self.applyCurrentState(snapshot: .current(), attemptReanchor: enableAfterSetup)
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

    private func showBlockedDockEdgeAlert(dockEdge: DockEdge, blockedDisplays: [String]) {
        let alert = NSAlert()
        alert.messageText = "No allowed display currently exposes the \(dockEdge.requirementDescription)."

        if blockedDisplays.isEmpty {
            alert.informativeText = "Rearrange your displays or change the macOS Dock position before enabling DockPin."
        } else {
            let summary = blockedDisplays.prefix(3).joined(separator: ", ")
            let suffix = blockedDisplays.count > 3 ? ", +\(blockedDisplays.count - 3) more" : ""
            alert.informativeText = "Rearrange your displays or change the macOS Dock position before enabling DockPin. Blocked: \(summary)\(suffix)."
        }

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
        applyCurrentState(snapshot: snapshot, attemptReanchor: true)
    }
}
