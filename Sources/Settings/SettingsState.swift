import CoreGraphics
import Foundation

/// The panes of the settings window.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case displays
    case profiles
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .displays: return L("Displays")
        case .profiles: return L("Profiles")
        case .general: return L("General")
        }
    }

    var symbolName: String {
        switch self {
        case .displays: return "display.2"
        case .profiles: return "rectangle.stack"
        case .general: return "gearshape"
        }
    }
}

/// The choices in the override key menu.
enum OverrideChoice: Hashable, Sendable {
    case modifier(ModifierOption)
    /// A key the user records.
    case custom
}

/// One display as the Displays pane shows it.
struct DisplayRow: Identifiable, Equatable, Sendable {
    var id: String
    var stableID: DisplayStableID
    var name: String
    var isBuiltIn: Bool
    var isConnected: Bool
    var isAllowed: Bool
    /// The Dock is on this display right now.
    var hasDock: Bool
    /// Why this display can't host the Dock in the current arrangement, if it can't.
    var blockedReason: String?
    /// False for the last allowed display: a profile always keeps one.
    var canDisallow: Bool

    var caption: String? {
        if !isConnected { return L("Not connected") }
        if let blockedReason { return blockedReason }
        if hasDock { return L("The Dock is here now") }
        return nil
    }
}

/// One profile as the Profiles pane shows it.
struct ProfileRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isActive: Bool
    /// The displays this profile auto-switches for, in words.
    var triggerSummary: String
}

enum LaunchAtLoginState: Equatable, Sendable {
    case off
    case on
    /// Registered, but the user has to allow it in System Settings.
    case needsApproval
}

/// Everything the settings window and the menu show, computed in one place so both always agree.
struct SettingsState: Equatable, Sendable {
    var lockStatus: LockStatus = .notConfigured
    /// False only when there are no profiles at all.
    var hasProfile = false
    /// Stored profiles exist but couldn't be read; starting over needs the user's say-so.
    var storedProfilesUnreadable = false

    var pinningEnabled = false
    /// One sentence on what DockPin is doing, for the Displays pane.
    var statusDetail = ""
    /// The same in a few words, for the menu.
    var menuStatus = ""
    /// Why pinning can't be switched on right now; nil when it can.
    var enableBlockedReason: String?
    var reanchorDisabledReason: String?

    var dockEdge: DockEdge = .bottom
    var overrideChoice: OverrideChoice = .modifier(.option)
    /// The recorded key, when the override is a custom one.
    var customOverrideKey: CustomOverrideKey?
    var displays: [DisplayRow] = []
    var connectedDisplayCount = 0

    var profiles: [ProfileRow] = []
    var activeProfileID: UUID?
    var activeProfileName = ""
    var autoSwitchEnabled = true
    /// Auto-switching is on but waiting, because the user picked a profile by hand.
    var autoSwitchPaused = false

    var isAccessibilityTrusted = false
    var showsMenuBarIcon = true
    var launchAtLogin: LaunchAtLoginState = .off
    var launchAtLoginError: String?
    var automaticallyChecksForUpdates = true
    /// False in a build without Sparkle, where there is nothing to check automatically.
    var showsAutomaticUpdateToggle = UpdateController.isSparkleBuilt
    var canCheckForUpdates = true
    var updateStatus: UpdateStatus = .idle
    var lastUpdateCheck: Date?
    var version = ""
}

extension SettingsState {
    /// What the state is computed from.
    struct Inputs {
        var profiles: [DockProfile]
        var activeProfileID: UUID?
        var storedProfilesUnreadable = false
        var snapshot: DisplaySnapshot
        var reachability: [CGDirectDisplayID: DisplayEdgeReachability]
        var dockEdge: DockEdge
        var lockStatus: LockStatus
        /// The display the Dock is on, when known.
        var dockDisplay: CGDirectDisplayID?
        /// Remembered display names by `DisplayStableID.storageKey`.
        var displayNames: [String: String] = [:]
        var hasSeparateSpaces = true
        var isAccessibilityTrusted = true
        var reanchorDisabledReason: String?
        var autoSwitchEnabled = true
        var manualHoldEnabled = false
        var showsMenuBarIcon = true
        var launchAtLogin: LaunchAtLoginState = .off
        var launchAtLoginError: String?
        var automaticallyChecksForUpdates = true
        var showsAutomaticUpdateToggle = UpdateController.isSparkleBuilt
        var canCheckForUpdates = true
        var updateStatus: UpdateStatus = .idle
        var lastUpdateCheck: Date?
        var version = ""
    }

    init(_ inputs: Inputs) {
        let active = inputs.profiles.first { $0.id == inputs.activeProfileID }
        let connected = inputs.snapshot.filtered(for: active?.mirroringPolicy ?? .ignoreMirroredSecondaries)

        lockStatus = inputs.lockStatus
        hasProfile = !inputs.profiles.isEmpty
        storedProfilesUnreadable = inputs.storedProfilesUnreadable
        pinningEnabled = active?.isEnabled ?? false
        dockEdge = inputs.dockEdge
        customOverrideKey = active?.customOverrideKey
        overrideChoice = customOverrideKey != nil ? .custom : .modifier(active?.overrideModifier ?? .option)
        connectedDisplayCount = connected.count
        reanchorDisabledReason = inputs.reanchorDisabledReason

        displays = Self.displayRows(
            active: active,
            connected: connected,
            reachability: inputs.reachability,
            dockEdge: inputs.dockEdge,
            dockDisplay: inputs.dockDisplay,
            displayNames: inputs.displayNames
        )

        let pinnedNames = connected
            .filter { active?.allows($0.stableID) == true && inputs.reachability[$0.displayID]?.isReachable == true }
            .map(\.localizedName)
        statusDetail = Self.statusDetail(inputs.lockStatus, pinnedTo: pinnedNames, dockEdge: inputs.dockEdge)
        menuStatus = Self.menuStatus(inputs.lockStatus, pinnedTo: pinnedNames, dockEdge: inputs.dockEdge)
        enableBlockedReason = Self.enableBlockedReason(
            active: active,
            connected: connected,
            reachability: inputs.reachability,
            dockEdge: inputs.dockEdge,
            hasSeparateSpaces: inputs.hasSeparateSpaces
        )

        profiles = inputs.profiles.map { profile in
            ProfileRow(
                id: profile.id,
                name: profile.name,
                isActive: profile.id == inputs.activeProfileID,
                triggerSummary: Self.triggerSummary(profile, displayNames: inputs.displayNames)
            )
        }
        activeProfileID = active?.id
        activeProfileName = active?.name ?? ""
        autoSwitchEnabled = inputs.autoSwitchEnabled
        autoSwitchPaused = inputs.autoSwitchEnabled && inputs.manualHoldEnabled

        isAccessibilityTrusted = inputs.isAccessibilityTrusted
        showsMenuBarIcon = inputs.showsMenuBarIcon
        launchAtLogin = inputs.launchAtLogin
        launchAtLoginError = inputs.launchAtLoginError
        automaticallyChecksForUpdates = inputs.automaticallyChecksForUpdates
        showsAutomaticUpdateToggle = inputs.showsAutomaticUpdateToggle
        canCheckForUpdates = inputs.canCheckForUpdates
        updateStatus = inputs.updateStatus
        lastUpdateCheck = inputs.lastUpdateCheck
        version = inputs.version
    }

    // MARK: - Pieces

    private static func displayRows(
        active: DockProfile?,
        connected: [DisplayDescriptor],
        reachability: [CGDirectDisplayID: DisplayEdgeReachability],
        dockEdge: DockEdge,
        dockDisplay: CGDirectDisplayID?,
        displayNames: [String: String]
    ) -> [DisplayRow] {
        let allowed = active?.allowedDisplays ?? []

        var rows = connected.map { display -> DisplayRow in
            let covering = active?.allowedIDs(covering: display.stableID) ?? []
            let isReachable = reachability[display.displayID]?.isReachable ?? true
            return DisplayRow(
                id: "connected-\(display.displayID)",
                stableID: display.stableID,
                name: display.localizedName,
                isBuiltIn: display.isBuiltIn,
                isConnected: true,
                isAllowed: !covering.isEmpty,
                hasDock: dockDisplay == display.displayID,
                blockedReason: isReachable
                    ? nil
                    : L("Can’t host the Dock on the %@: %@", dockEdge.nameInSentence, dockEdge.blockedDirectionDescription),
                // Turning this display off removes every stored ID that covers it.
                canDisallow: allowed.count - covering.count >= 1
            )
        }

        // Displays the profile allows that aren't plugged in right now.
        let missing = allowed
            .filter { stored in !connected.contains { stored.covers($0.stableID) } }
            .sorted { $0.storageKey < $1.storageKey }
        rows += missing.map { stored in
            DisplayRow(
                id: "missing-\(stored.storageKey)",
                stableID: stored,
                name: displayNames[stored.storageKey] ?? L("Unknown display"),
                isBuiltIn: false,
                isConnected: false,
                isAllowed: true,
                hasDock: false,
                blockedReason: nil,
                canDisallow: allowed.count > 1
            )
        }
        return rows
    }

    private static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: return L("the allowed display")
        case 1: return names[0]
        case 2: return L("%@ and %@", names[0], names[1])
        default: return L("%@ displays", String(names.count))
        }
    }

    static func statusDetail(_ status: LockStatus, pinnedTo names: [String], dockEdge: DockEdge) -> String {
        switch status {
        case .notConfigured:
            return L("DockPin isn’t set up yet.")
        case .disabled:
            return L("Off. The Dock can move to any display.")
        case .locking:
            return L("Keeping the Dock on %@.", listed(names))
        case .needsAccessibility:
            return L("Waiting for Accessibility access.")
        case .separateSpacesOff:
            return L("“Displays have separate Spaces” is off, so macOS keeps the Dock on the main display.")
        case .allowedDisplayMissing:
            return L("Idle. None of the allowed displays is connected.")
        case .edgeBlocked:
            return L("Idle. No allowed display has a free %@ edge in this arrangement.", dockEdge.nameInSentence)
        case .tapUnavailable:
            return L("Couldn’t start. Try quitting and reopening DockPin.")
        }
    }

    static func menuStatus(_ status: LockStatus, pinnedTo names: [String], dockEdge: DockEdge) -> String {
        switch status {
        case .notConfigured: return L("DockPin isn’t set up")
        case .disabled: return L("DockPin is off")
        case .locking: return L("Pinned to %@", listed(names))
        default: return status.explanation(dockEdge: dockEdge) ?? L("DockPin is idle")
        }
    }

    private static func enableBlockedReason(
        active: DockProfile?,
        connected: [DisplayDescriptor],
        reachability: [CGDirectDisplayID: DisplayEdgeReachability],
        dockEdge: DockEdge,
        hasSeparateSpaces: Bool
    ) -> String? {
        guard let active else { return L("Set up DockPin first.") }
        if active.isEnabled { return nil }
        if !hasSeparateSpaces {
            return L("Turn on “Displays have separate Spaces” in System Settings → Desktop & Dock, then log out and back in.")
        }
        if connected.count < 2 { return L("Connect a second display to use DockPin.") }

        let allowedConnected = connected.filter { active.allows($0.stableID) }
        if allowedConnected.isEmpty { return L("Allow at least one connected display first.") }
        if !allowedConnected.contains(where: { reachability[$0.displayID]?.isReachable == true }) {
            return L("No allowed display has a free %@ edge in this arrangement.", dockEdge.nameInSentence)
        }
        return nil
    }

    private static func triggerSummary(_ profile: DockProfile, displayNames: [String: String]) -> String {
        guard let requirements = profile.triggerRequirements, !requirements.isEmpty else {
            return L("Not linked to any displays")
        }
        let names = requirements.keys
            .sorted { $0.storageKey < $1.storageKey }
            .map { displayNames[$0.storageKey] ?? L("an unknown display") }
        let formatter = ListFormatter()
        formatter.locale = Localization.shared.locale
        let joined = formatter.string(from: names) ?? names.joined(separator: ", ")
        return L("Linked to ") + joined
    }
}

/// Whether the menu bar icon should be on screen.
enum StatusItemVisibility {
    /// A hidden icon comes back while DockPin needs the user to do something, because with the
    /// icon gone there would be no sign that it has stopped working.
    static func shouldShow(hiddenByUser: Bool, needsAttention: Bool) -> Bool {
        !hiddenByUser || needsAttention
    }
}
