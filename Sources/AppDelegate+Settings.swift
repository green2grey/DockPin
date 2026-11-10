import AppKit
import ServiceManagement

// Everything the settings window and the menu can ask for, and the state they show.
extension AppDelegate: SettingsActions {

    // MARK: - Showing things

    func showSettings(pane: SettingsPane? = nil) {
        refreshSettingsState()
        settingsWindowController.show(pane: pane)
    }

    /// Recomputes what the menu and the settings window show.
    func refreshSettingsState() {
        let snapshot = DisplaySnapshot.current()
        profileManager.rememberDisplayNames(from: snapshot)

        let active = profileManager.activeProfile
        let dockEdge = DockEdge.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(
            snapshot: snapshot,
            edge: dockEdge,
            mirroringPolicy: active?.mirroringPolicy ?? .ignoreMirroredSecondaries
        )
        let resolvedAllowed = active.map { profileManager.resolveAllowedDisplayIDs(for: $0, snapshot: snapshot) } ?? []

        var dockDisplay: CGDirectDisplayID?
        if case .display(let id) = DockLocator.current(snapshot: snapshot, edge: dockEdge) {
            dockDisplay = id
        }

        settingsModel.state = SettingsState(SettingsState.Inputs(
            profiles: profileManager.profiles,
            activeProfileID: profileManager.activeProfileID,
            storedProfilesUnreadable: profileManager.storedProfilesUnreadable,
            snapshot: snapshot,
            reachability: reachability,
            dockEdge: dockEdge,
            lockStatus: lockStatus,
            dockDisplay: dockDisplay,
            displayNames: profileManager.displayNames,
            hasSeparateSpaces: NSScreen.screensHaveSeparateSpaces,
            isAccessibilityTrusted: isAccessibilityTrusted(),
            reanchorDisabledReason: reanchorPlan(
                activeProfile: active,
                resolvedAllowed: resolvedAllowed,
                reachability: reachability
            ).disabledReason,
            autoSwitchEnabled: profileManager.autoSwitchEnabled,
            manualHoldEnabled: profileManager.manualHoldEnabled,
            showsMenuBarIcon: !profileManager.hidesMenuBarIcon,
            launchAtLogin: Self.launchAtLoginState,
            launchAtLoginError: launchAtLoginError,
            automaticallyChecksForUpdates: updates.automaticallyChecksForUpdates,
            canCheckForUpdates: updates.canCheckForUpdates,
            updateStatus: updates.status,
            lastUpdateCheck: updates.lastCheckDate,
            version: Self.versionDescription
        ))
    }

    private static var launchAtLoginState: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    // MARK: - Pinning and displays

    func setPinningEnabled(_ enabled: Bool) {
        guard isConfigured, let active = profileManager.activeProfile else { return }

        if enabled {
            refreshSettingsState()
            // The controls are disabled when pinning can't start; this covers a stale click.
            guard settingsModel.state.enableBlockedReason == nil else { return }
            profileManager.updateProfile(id: active.id) { $0.isEnabled = true }
            if !isAccessibilityTrusted() {
                promptAccessibilityIfNeeded()
            }
        } else {
            profileManager.updateProfile(id: active.id) { $0.isEnabled = false }
        }

        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    func setDisplay(_ display: DisplayRow, allowed: Bool) {
        guard isConfigured, let active = profileManager.activeProfile else { return }

        if allowed {
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.insert(display.stableID) }
        } else {
            let covering = active.allowedIDs(covering: display.stableID)
            // A profile always keeps one allowed display.
            guard active.allowedDisplays.count - covering.count >= 1 else {
                refreshSettingsState()
                return
            }
            profileManager.updateProfile(id: active.id) { $0.allowedDisplays.subtract(covering) }
        }

        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    func setOverrideModifier(_ modifier: ModifierOption) {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        profileManager.updateProfile(id: active.id) {
            $0.overrideModifier = modifier
            $0.customOverrideKey = nil
        }
        applyCurrentState(snapshot: .current())
    }

    func setCustomOverrideKey(_ key: CustomOverrideKey) {
        guard isConfigured, let active = profileManager.activeProfile else { return }
        profileManager.updateProfile(id: active.id) { $0.customOverrideKey = key }
        applyCurrentState(snapshot: .current())
    }

    func reanchorNow() {
        startReanchor(mode: .manual)
    }

    // MARK: - Profiles

    func createFirstProfile() {
        guard profileManager.profiles.isEmpty else { return }
        createDefaultProfile()
        applyCurrentState(snapshot: .current())
    }

    func selectProfile(_ id: UUID) {
        let snapshot = DisplaySnapshot.current()
        profileManager.setActiveProfile(id: id, manualHold: true)
        profileManager.learnTriggerIfMissing(id: id, snapshot: snapshot)
        applyCurrentState(snapshot: snapshot, attemptReanchor: true)
    }

    func addProfile() -> UUID? {
        let snapshot = DisplaySnapshot.current()
        let created = profileManager.saveCurrentAsProfile(
            name: profileManager.unusedProfileName(),
            snapshot: snapshot
        )
        applyCurrentState(snapshot: snapshot)
        return created?.id
    }

    func renameProfile(_ id: UUID, to name: String) {
        profileManager.renameProfile(id: id, to: name)
        refreshPresentation()
    }

    func deleteProfile(_ id: UUID) {
        // The last profile stays; there is always one to edit.
        guard profileManager.profiles.count > 1 else { return }
        profileManager.deleteProfile(id: id)
        applyCurrentState(snapshot: .current(), attemptReanchor: true)
    }

    func linkProfileToCurrentDisplays(_ id: UUID) {
        profileManager.relinkTrigger(id: id, snapshot: .current())
        refreshSettingsState()
    }

    func setAutoSwitch(_ enabled: Bool) {
        profileManager.autoSwitchEnabled = enabled
        if enabled {
            scheduleAutoSwitch()
        }
        refreshSettingsState()
    }

    func resumeAutoSwitching() {
        profileManager.manualHoldEnabled = false
        scheduleAutoSwitch()
        refreshSettingsState()
    }

    // MARK: - General

    func setShowsMenuBarIcon(_ shows: Bool) {
        profileManager.hidesMenuBarIcon = !shows
        refreshPresentation()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn’t change the login item: \(error.localizedDescription)"
        }
        refreshSettingsState()
    }

    // MARK: - Updates

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        updates.automaticallyChecksForUpdates = enabled
        refreshSettingsState()
    }

    func checkForUpdates() {
        updates.checkForUpdates()
    }

    func cancelUpdate() {
        updates.cancel()
    }

    func installUpdate() {
        if case .available(let info) = updates.status, info.isInformationOnly {
            // Nothing to download: this update is a page to read.
            showUpdateDetails()
        }
        updates.install()
    }

    func skipUpdate() {
        updates.skip()
    }

    func postponeUpdate() {
        updates.later()
    }

    func installUpdateAndRelaunch() {
        updates.installAndRelaunch()
    }

    func showUpdateDetails() {
        var url = URL(string: "https://github.com/green2grey/DockPin/releases")
        if case .available(let info) = updates.status, let details = info.detailsURL {
            url = details
        }
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Links and help

    func openAccessibilitySettings() {
        promptAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openWebsite() {
        if let url = URL(string: "https://green2grey.github.io/DockPin/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openIssueTracker() {
        if let url = URL(string: "https://github.com/green2grey/DockPin/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    func showHelp() {
        textWindows.show(id: "help", title: "DockPin Help", content: HelpContent.attributedString())
    }

    func showWhatsNew() {
        let entries = Changelog.bundled()
        guard !entries.isEmpty else {
            // A build without the bundled changelog still has somewhere to send people.
            if let url = URL(string: "https://github.com/green2grey/DockPin/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        textWindows.show(
            id: "whats-new",
            title: "What’s New in DockPin",
            content: Changelog.attributedString(for: entries)
        )
    }
}
