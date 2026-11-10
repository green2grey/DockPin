import AppKit
import ServiceManagement

/// The app's engine room: lifecycle, the decision of whether DockPin should be locking right now,
/// and the automatic re-anchor checks. The menu lives in `AppDelegate+Menu.swift` and everything
/// the settings window can ask for in `AppDelegate+Settings.swift`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Shared with the extensions in the other AppDelegate files.
    var statusItem: NSStatusItem!
    let textWindows = TextWindows()
    var lockStatus: LockStatus = .notConfigured
    var launchAtLoginError: String?
    var isSettingsVisible = false

    let monitor = DockMonitor()
    let dockReanchorer = DockReanchorer()
    let profileManager = ProfileManager()
    let settingsModel = SettingsModel()
    lazy var settingsWindowController = SettingsWindowController(model: settingsModel)
    let updates = UpdateController()

    private var autoSwitchTask: Task<Void, Never>?
    private var screenChangeTick = 0
    private var recoveryTask: Task<Void, Never>?
    private var environmentTimer: Timer?
    private var lastEnvironment: EnvironmentState?
    // Set from notifications only; `sessionAllowsReanchor` cross-checks them against the session
    // itself so one missed notification can't switch re-anchoring off for good.
    private var systemAsleep = false
    private var screenLocked = false

    private static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// How long after the user pushes through a blocked edge with the override modifier a Dock
    /// move still counts as theirs.
    private static let overrideGracePeriod: TimeInterval = 5

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Worked out first, before anything below leaves its own traces in the saved settings.
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let showWhatsNewAfterLaunch = UpgradeNotice.shouldShow(
            previousVersion: profileManager.lastRunVersion,
            currentVersion: currentVersion,
            hadEarlierInstall: profileManager.setupCompleted
                || !profileManager.profiles.isEmpty
                || UserDefaults.standard.object(forKey: "SUHasLaunchedBefore") != nil
        )
        profileManager.lastRunVersion = currentVersion

        MainMenu.install()
        setupStatusBar()
        settingsModel.actions = self
        settingsWindowController.onVisibilityChange = { [weak self] visible in
            self?.isSettingsVisible = visible
            self?.refreshSettingsState()
            self?.updateEnvironmentWatcher()
        }
        settingsWindowController.onBecomeKey = { [weak self] in
            self?.refreshSettingsState()
        }
        updates.onChange = { [weak self] in
            self?.updatesDidChange()
        }
        updates.onShowInFocus = { [weak self] in
            self?.showSettings(pane: .general)
        }
        updates.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceNotifications.addObserver(self, selector: #selector(resumeSession), name: name, object: nil)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceNotifications.addObserver(self, selector: #selector(suspendSession), name: name, object: nil)
        }
        // Distributed notifications are held back while an app is inactive unless it asks
        // otherwise, and a menu bar app is inactive nearly all the time.
        let distributedNotifications = DistributedNotificationCenter.default()
        distributedNotifications.addObserver(self, selector: #selector(resumeSession),
                                             name: Self.screenUnlockedNotification, object: nil,
                                             suspensionBehavior: .deliverImmediately)
        distributedNotifications.addObserver(self, selector: #selector(suspendSession),
                                             name: Self.screenLockedNotification, object: nil,
                                             suspensionBehavior: .deliverImmediately)

        monitor.onAccessibilityLost = { [weak self] in
            MainActor.assumeIsolated {
                self?.applyCurrentState(snapshot: .current())
            }
        }

        #if DOCKPIN_DEV
        // Dev builds only (see build-dev.sh): lets a script ask for a re-anchor, so gesture
        // timings can be tried against the real Dock without clicking through the menu.
        // The names carry this copy's bundle ID, so two dev copies running side by side (the
        // everyday one and an update rehearsal) can't set each other off.
        let devPrefix = Bundle.main.bundleIdentifier ?? "com.green2grey.DockPin.dev"
        distributedNotifications.addObserver(self, selector: #selector(devReanchorRequested),
                                             name: Notification.Name("\(devPrefix).reanchor"),
                                             object: nil, suspensionBehavior: .deliverImmediately)
        // And to walk through an update, for rehearsing a release against a test feed.
        distributedNotifications.addObserver(self, selector: #selector(devUpdateStepRequested(_:)),
                                             name: Notification.Name("\(devPrefix).update"),
                                             object: nil, suspensionBehavior: .deliverImmediately)
        #endif

        #if DOCKPIN_DEV
        // An update rehearsal runs a throwaway copy unattended: it shouldn't ask for permissions
        // or put windows up.
        if UserDefaults.standard.bool(forKey: "dev.updateRehearsal") {
            applyCurrentState(snapshot: .current())
            return
        }
        #endif

        let isFirstRun = createDefaultProfileIfNeeded()

        promptAccessibilityIfNeeded()
        let openSettingsAfterReset = handleV1ResetNoticeIfNeeded()
        reportProfileLoadIssueIfNeeded()

        applyCurrentState(snapshot: .current())
        scheduleRecovery()

        if isFirstRun || openSettingsAfterReset || !isConfigured {
            showSettings(pane: .displays)
        }
        if showWhatsNewAfterLaunch {
            showWhatsNew()
        }
    }

    /// Opening DockPin while it's already running (from Finder, Spotlight, the Dock) brings up
    /// Settings. With the menu bar icon hidden, this is the way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTask?.cancel()
        environmentTimer?.invalidate()
        dockReanchorer.cancel()
        monitor.stopLocking()
    }

    #if DOCKPIN_DEV
    @objc private func devReanchorRequested() {
        startReanchor(mode: .manual)
    }

    /// The step to take is the notification's object: check, install, relaunch, later, skip, cancel.
    @objc private func devUpdateStepRequested(_ notification: Notification) {
        switch notification.object as? String {
        case "check": updates.checkForUpdates()
        case "install": updates.install()
        case "relaunch": updates.installAndRelaunch()
        case "later": updates.later()
        case "skip": updates.skip()
        case "cancel": updates.cancel()
        default: break
        }
    }
    #endif

    // MARK: - Display and session events

    @objc private func screensChanged() {
        applyCurrentState(snapshot: .current())
        scheduleAutoSwitch()

        // A Dock move posts this notification too. If the user just pushed through a blocked
        // edge with the override modifier, the move is theirs: don't drag the Dock back.
        if monitor.overrideBypassed(within: Self.overrideGracePeriod) || monitor.isOverrideDown {
            recoveryTask?.cancel()
            recoveryTask = nil
            dockReanchorer.cancel()
            return
        }
        scheduleRecovery()
    }

    @objc private func suspendSession(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case Self.screenLockedNotification: screenLocked = true
        default: break
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        dockReanchorer.cancel()
    }

    @objc private func resumeSession(_ notification: Notification) {
        // Screens waking, the session coming back, or an unlock all mean the Mac is awake, so a
        // missed did-wake notification can't leave this stuck.
        systemAsleep = false
        if notification.name == Self.screenUnlockedNotification {
            screenLocked = false
        }
        scheduleRecovery()
    }

    /// Whether the user is at an awake, unlocked, frontmost session, checked against the session
    /// itself and not only against the notifications received so far.
    private func sessionAllowsReanchor() -> Bool {
        if systemAsleep { return false }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }

        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        else {
            // No session information to go on; fall back to what the notifications said.
            return !screenLocked
        }

        guard onConsole else { return false }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        // The session reports itself unlocked, so an unlock notification must have been missed.
        screenLocked = false
        return true
    }

    // MARK: - Re-anchoring

    /// Re-checks the Dock a moment after something that may have moved it (launch, display
    /// change, wake, unlock), once things have settled.
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        dockReanchorer.cancel()
        guard sessionAllowsReanchor() else { return }
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            self.applyCurrentState(snapshot: .current(), attemptReanchor: true)
        }
    }

    func startReanchor(mode: DockReanchorer.Mode) {
        dockReanchorer.reanchor(mode: mode) { [weak self] in
            guard let self else { return nil }
            // The user is plainly present for a manual request; automatic ones wait for a usable
            // session and stand down while the override modifier is held.
            if mode == .automatic {
                guard self.sessionAllowsReanchor(), !self.monitor.isOverrideDown else { return nil }
            }
            return self.currentReanchorTarget()
        }
    }

    /// The display edge a re-anchor should aim for right now, or nil when one isn't possible.
    private func currentReanchorTarget() -> DisplayEdgeReachability? {
        guard isConfigured, let active = profileManager.activeProfile else { return nil }
        let snapshot = DisplaySnapshot.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: DockEdge.current(),
            mirroringPolicy: active.mirroringPolicy
        )
        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)
        return reanchorPlan(
            activeProfile: active,
            resolvedAllowed: resolvedAllowed,
            reachability: reachability
        ).target
    }

    struct ReanchorPlan {
        var target: DisplayEdgeReachability?
        var disabledReason: String?
    }

    func reanchorPlan(
        activeProfile: DockProfile?,
        resolvedAllowed: Set<CGDirectDisplayID>,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> ReanchorPlan {
        guard let activeProfile else {
            return ReanchorPlan(target: nil, disabledReason: "Set up DockPin first.")
        }
        guard activeProfile.isEnabled else {
            return ReanchorPlan(target: nil, disabledReason: "Turn on pinning first.")
        }
        guard isAccessibilityTrusted() else {
            return ReanchorPlan(target: nil, disabledReason: "Grant Accessibility access first.")
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            return ReanchorPlan(target: nil, disabledReason: "Needs “Displays have separate Spaces” turned on.")
        }
        guard reachability.count >= 2 else {
            return ReanchorPlan(target: nil, disabledReason: "Needs two or more displays.")
        }
        guard !resolvedAllowed.isEmpty else {
            return ReanchorPlan(target: nil, disabledReason: "None of the allowed displays is connected.")
        }
        guard resolvedAllowed.count == 1, let displayID = resolvedAllowed.first else {
            return ReanchorPlan(
                target: nil,
                disabledReason: "Works when exactly one connected display is allowed, so DockPin knows where to send the Dock."
            )
        }
        guard let target = reachability[displayID] else {
            return ReanchorPlan(target: nil, disabledReason: "The allowed display isn’t available right now.")
        }
        guard target.isReachable else {
            return ReanchorPlan(target: nil, disabledReason: target.blockedReason)
        }
        return ReanchorPlan(target: target, disabledReason: nil)
    }

    // MARK: - Deciding what to do

    var isConfigured: Bool {
        profileManager.setupCompleted && !profileManager.profiles.isEmpty
    }

    func promptAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func reachableAllowedDisplayIDs(
        resolvedAllowed: Set<CGDirectDisplayID>,
        reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    ) -> Set<CGDirectDisplayID> {
        Set(resolvedAllowed.filter { reachability[$0]?.isReachable == true })
    }

    /// The outside conditions that decide whether an enabled profile can lock. None of them
    /// announces a change, so they're polled while they matter.
    private struct EnvironmentState: Equatable {
        var isTrusted: Bool
        var dockEdge: DockEdge
        var hasSeparateSpaces: Bool

        @MainActor
        static func current() -> EnvironmentState {
            EnvironmentState(
                isTrusted: AXIsProcessTrusted(),
                dockEdge: .current(),
                hasSeparateSpaces: NSScreen.screensHaveSeparateSpaces
            )
        }
    }

    /// Brings the event tap, the icon, the menu and the settings window in line with the current
    /// profile, displays and permissions. Safe to call any time something may have changed.
    func applyCurrentState(snapshot: DisplaySnapshot, attemptReanchor: Bool = false) {
        let environment = EnvironmentState.current()
        lastEnvironment = environment

        guard isConfigured else {
            recoveryTask?.cancel()
            recoveryTask = nil
            dockReanchorer.cancel()
            monitor.stopLocking()
            monitor.allowedDisplays.removeAll()
            lockStatus = .notConfigured
            refreshPresentation()
            return
        }

        if profileManager.activeProfileID == nil, let first = profileManager.profiles.first {
            profileManager.setActiveProfile(id: first.id, manualHold: false)
        }
        guard let active = profileManager.activeProfile else {
            refreshPresentation()
            return
        }

        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: environment.dockEdge,
            mirroringPolicy: active.mirroringPolicy
        )
        let resolvedAllowed = profileManager.resolveAllowedDisplayIDs(for: active, snapshot: snapshot)
        let reachableAllowed = reachableAllowedDisplayIDs(resolvedAllowed: resolvedAllowed, reachability: reachability)
        monitor.allowedDisplays = resolvedAllowed
        monitor.overrideTrigger = active.overrideTrigger

        func status(isLocking: Bool) -> LockStatus {
            LockStatus.evaluate(
                isConfigured: true,
                profileEnabled: active.isEnabled,
                isTrusted: environment.isTrusted,
                hasSeparateSpaces: environment.hasSeparateSpaces,
                hasAllowedDisplay: !resolvedAllowed.isEmpty,
                hasReachableAllowedDisplay: !reachableAllowed.isEmpty,
                isLocking: isLocking
            )
        }

        if status(isLocking: true).permitsLocking {
            monitor.startLocking()
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
            dockReanchorer.cancel()
            monitor.stopLocking()
        }

        if monitor.isEnabled {
            monitor.refreshScreenCache()
        }
        lockStatus = status(isLocking: monitor.isEnabled)

        if attemptReanchor, monitor.isEnabled {
            startReanchor(mode: .automatic)
        }

        #if DOCKPIN_DEV
        UserDefaults.standard.set(String(describing: lockStatus), forKey: "dev.lockStatus")
        #endif

        refreshPresentation()
    }

    /// An update check or install moved on. This can fire many times a second during a download,
    /// so it touches only what shows update progress.
    private func updatesDidChange() {
        settingsModel.state.updateStatus = updates.status
        settingsModel.state.lastUpdateCheck = updates.lastCheckDate
        settingsModel.state.canCheckForUpdates = updates.canCheckForUpdates
        updateStatusItem()
        #if DOCKPIN_DEV
        UserDefaults.standard.set(String(describing: updates.status), forKey: "dev.updateStatus")
        #endif
    }

    /// Updates everything the user can see, and the poll that keeps it current.
    func refreshPresentation() {
        updateStatusItem()
        refreshSettingsState()
        updateEnvironmentWatcher()
    }

    /// Runs the environment poll while its answer matters: a profile is on, or Settings is open
    /// and showing permission state.
    func updateEnvironmentWatcher() {
        let needed = profileManager.activeProfile?.isEnabled == true || isSettingsVisible
        guard needed else {
            environmentTimer?.invalidate()
            environmentTimer = nil
            return
        }
        guard environmentTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.environmentTick()
            }
        }
        timer.tolerance = 0.25
        environmentTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func environmentTick() {
        let environment = EnvironmentState.current()
        guard environment != lastEnvironment else { return }
        // Access was just granted, the Dock moved to another edge, and so on: re-evaluate, and
        // check the Dock's position since locking may be starting only now.
        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    // MARK: - First run and one-off notices

    /// On a clean first launch, starts the user off with a profile that allows the display the
    /// Dock is on now, so all that's left is to turn pinning on. Returns true if it made one.
    private func createDefaultProfileIfNeeded() -> Bool {
        // Unreadable saved data is still in place; replacing it is the user's call.
        guard profileManager.profiles.isEmpty, !profileManager.storedProfilesUnreadable else { return false }
        createDefaultProfile()
        return true
    }

    func createDefaultProfile() {
        let snapshot = DisplaySnapshot.current()
        let connected = snapshot.filtered(for: .ignoreMirroredSecondaries)

        var dockDisplay: CGDirectDisplayID?
        if case .display(let id) = DockLocator.current(snapshot: snapshot) { dockDisplay = id }
        let home = connected.first { $0.displayID == dockDisplay }
            ?? connected.first { $0.displayID == CGMainDisplayID() }
            ?? connected.first

        let profile = DockProfile(
            name: profileManager.unusedProfileName(base: "Default"),
            isEnabled: false,
            overrideModifier: .option,
            allowedDisplays: home.map { [$0.stableID] } ?? [],
            triggerRequirements: ProfileManager.triggerRequirements(
                for: snapshot,
                mirroringPolicy: .ignoreMirroredSecondaries
            )
        )
        profileManager.addProfile(profile, makeActive: true)
        profileManager.setupCompleted = true
        profileManager.manualHoldEnabled = false
    }

    private func reportProfileLoadIssueIfNeeded() {
        guard let issue = profileManager.unacknowledgedLoadIssue else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch issue {
        case .skippedProfiles(let count):
            alert.messageText = count == 1
                ? "One saved profile couldn’t be read"
                : "\(count) saved profiles couldn’t be read"
            alert.informativeText = "DockPin left them out and kept a backup copy of the original data. Your other profiles are unaffected."
        case .unreadable:
            alert.messageText = "DockPin couldn’t read your saved profiles"
            alert.informativeText = "The saved data is damaged or was written by a different version. DockPin kept a backup copy; you can start fresh from Settings."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        profileManager.acknowledgeLoadIssue()
    }

    private func v1KeysPresent() -> Bool {
        let d = UserDefaults.standard
        let hasAllowed = (d.array(forKey: "allowedDisplays") as? [Int])?.isEmpty == false
        let hasEnabled = d.object(forKey: "isEnabled") != nil
        let hasOverride = d.object(forKey: "overrideModifier") != nil
        return hasAllowed || hasEnabled || hasOverride
    }

    /// Tells someone coming from version 1 that their settings didn't carry over. Returns true
    /// if they asked to go to Settings.
    private func handleV1ResetNoticeIfNeeded() -> Bool {
        guard v1KeysPresent(), !profileManager.resetNoticeShown else { return false }

        let alert = NSAlert()
        alert.messageText = "DockPin Has Been Updated"
        alert.informativeText = "This update resets previous settings. Please choose your displays again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        profileManager.resetNoticeShown = true

        let d = UserDefaults.standard
        d.removeObject(forKey: "allowedDisplays")
        d.removeObject(forKey: "isEnabled")
        d.removeObject(forKey: "overrideModifier")

        return response == .alertFirstButtonReturn
    }

    // MARK: - Auto-switching

    func scheduleAutoSwitch() {
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
