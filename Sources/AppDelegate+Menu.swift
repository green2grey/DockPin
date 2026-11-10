import AppKit

// The menu bar icon and its menu. The menu is deliberately short: what DockPin is doing, the
// two everyday actions, a profile switch, and the way into Settings. Everything else lives in the
// settings window.
extension AppDelegate {

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        updateStatusItem()
    }

    /// Sets the icon to match what DockPin is doing, and shows or hides it.
    func updateStatusItem() {
        statusItem.isVisible = StatusItemVisibility.shouldShow(
            hiddenByUser: profileManager.hidesMenuBarIcon,
            needsAttention: lockStatus.needsAttention || updates.hasUnrequestedUpdate
        )

        guard let button = statusItem.button else { return }
        let profileName = profileManager.activeProfile?.name ?? "Profile"

        let symbol: String
        let fallback: String
        let tooltip: String

        // A filled pin only while the Dock is actually being held in place.
        switch lockStatus {
        case .notConfigured:
            symbol = "pin.slash"
            fallback = "lock.open"
            tooltip = "DockPin — Not set up"
        case .disabled:
            symbol = "pin"
            fallback = "lock"
            tooltip = "DockPin — Off"
        case .locking:
            symbol = "pin.fill"
            fallback = "lock.fill"
            tooltip = "DockPin — \(profileName)"
        case .needsAccessibility, .tapUnavailable:
            symbol = "exclamationmark.triangle"
            fallback = "lock.slash"
            tooltip = "DockPin — \(lockStatus.explanation(dockEdge: DockEdge.current()) ?? "Not running")"
        case .separateSpacesOff, .allowedDisplayMissing, .edgeBlocked:
            symbol = "pin"
            fallback = "lock"
            tooltip = "DockPin — \(profileName) (\(lockStatus.explanation(dockEdge: DockEdge.current()) ?? "idle"))"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: tooltip)
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip
    }

    fileprivate func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshSettingsState()
        let state = settingsModel.state

        // ── What DockPin is doing ──
        if state.lockStatus == .needsAccessibility {
            let grant = NSMenuItem(
                title: "\(state.menuStatus) — Open System Settings…",
                action: #selector(openAccessibilitySettingsFromMenu),
                keyEquivalent: ""
            )
            grant.target = self
            grant.image = Self.warningIcon
            menu.addItem(grant)
        } else {
            let status = NSMenuItem(title: state.menuStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            if state.lockStatus.needsAttention { status.image = Self.warningIcon }
            menu.addItem(status)
        }

        if state.updateStatus.awaitsDecision {
            let update = NSMenuItem(title: "Update Available…", action: #selector(openUpdatesFromMenu), keyEquivalent: "")
            update.target = self
            update.image = Self.updateIcon
            menu.addItem(update)
        }

        menu.addItem(.separator())

        if state.hasProfile {
            // ── Everyday actions ──
            let pin = NSMenuItem(title: "Pin the Dock", action: #selector(togglePinningFromMenu), keyEquivalent: "e")
            pin.keyEquivalentModifierMask = [.command]
            pin.target = self
            pin.state = state.pinningEnabled ? .on : .off
            pin.isEnabled = state.pinningEnabled || state.enableBlockedReason == nil
            pin.toolTip = state.pinningEnabled ? nil : state.enableBlockedReason
            menu.addItem(pin)

            let reanchor = NSMenuItem(title: "Re-anchor Dock Now", action: #selector(reanchorFromMenu), keyEquivalent: "")
            reanchor.target = self
            reanchor.isEnabled = state.reanchorDisabledReason == nil
            reanchor.toolTip = state.reanchorDisabledReason
            menu.addItem(reanchor)

            if state.profiles.count > 1 {
                let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
                let profileMenu = NSMenu()
                for profile in state.profiles {
                    let item = NSMenuItem(title: profile.name, action: #selector(selectProfileFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile.id
                    item.state = profile.isActive ? .on : .off
                    profileMenu.addItem(item)
                }
                if state.autoSwitchPaused {
                    profileMenu.addItem(.separator())
                    let resume = NSMenuItem(title: "Resume Auto-switching", action: #selector(resumeAutoSwitchingFromMenu), keyEquivalent: "")
                    resume.target = self
                    profileMenu.addItem(resume)
                }
                profileItem.submenu = profileMenu
                menu.addItem(profileItem)
            }

            menu.addItem(.separator())
        }

        // ── Settings and Quit ──
        let settings = NSMenuItem(
            title: state.hasProfile ? "DockPin Settings…" : "Set Up DockPin…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit DockPin", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
    }

    private static let warningIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Needs attention")
        image?.isTemplate = true
        return image
    }()

    private static let updateIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update available")
        image?.isTemplate = true
        return image
    }()

    // MARK: - Menu actions

    @objc private func openUpdatesFromMenu() {
        showSettings(pane: .general)
    }

    @objc private func togglePinningFromMenu() {
        setPinningEnabled(!settingsModel.state.pinningEnabled)
    }

    @objc private func reanchorFromMenu() {
        reanchorNow()
    }

    @objc private func selectProfileFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectProfile(id)
    }

    @objc private func resumeAutoSwitchingFromMenu() {
        resumeAutoSwitching()
    }

    @objc private func openAccessibilitySettingsFromMenu() {
        openAccessibilitySettings()
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate – rebuild the items each time the menu opens

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
