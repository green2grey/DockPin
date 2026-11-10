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
        case .displays: return "Displays"
        case .profiles: return "Profiles"
        case .general: return "General"
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
        if !isConnected { return "Not connected" }
        if let blockedReason { return blockedReason }
        if hasDock { return "The Dock is here now" }
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
                    : "Can’t host the Dock on the \(dockEdge.rawValue): \(dockEdge.blockedDirectionDescription)",
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
                name: displayNames[stored.storageKey] ?? "Unknown display",
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
        case 0: return "the allowed display"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) displays"
        }
    }

    static func statusDetail(_ status: LockStatus, pinnedTo names: [String], dockEdge: DockEdge) -> String {
        switch status {
        case .notConfigured:
            return "DockPin isn’t set up yet."
        case .disabled:
            return "Off. The Dock can move to any display."
        case .locking:
            return "Keeping the Dock on \(listed(names))."
        case .needsAccessibility:
            return "Waiting for Accessibility access."
        case .separateSpacesOff:
            return "“Displays have separate Spaces” is off, so macOS keeps the Dock on the main display."
        case .allowedDisplayMissing:
            return "Idle. None of the allowed displays is connected."
        case .edgeBlocked:
            return "Idle. No allowed display has a free \(dockEdge.rawValue) edge in this arrangement."
        case .tapUnavailable:
            return "Couldn’t start. Try quitting and reopening DockPin."
        }
    }

    static func menuStatus(_ status: LockStatus, pinnedTo names: [String], dockEdge: DockEdge) -> String {
        switch status {
        case .notConfigured: return "DockPin isn’t set up"
        case .disabled: return "DockPin is off"
        case .locking: return "Pinned to \(listed(names))"
        default: return status.explanation(dockEdge: dockEdge) ?? "DockPin is idle"
        }
    }

    private static func enableBlockedReason(
        active: DockProfile?,
        connected: [DisplayDescriptor],
        reachability: [CGDirectDisplayID: DisplayEdgeReachability],
        dockEdge: DockEdge,
        hasSeparateSpaces: Bool
    ) -> String? {
        guard let active else { return "Set up DockPin first." }
        if active.isEnabled { return nil }
        if !hasSeparateSpaces {
            return "Turn on “Displays have separate Spaces” in System Settings → Desktop & Dock, then log out and back in."
        }
        if connected.count < 2 { return "Connect a second display to use DockPin." }

        let allowedConnected = connected.filter { active.allows($0.stableID) }
        if allowedConnected.isEmpty { return "Allow at least one connected display first." }
        if !allowedConnected.contains(where: { reachability[$0.displayID]?.isReachable == true }) {
            return "No allowed display has a free \(dockEdge.rawValue) edge in this arrangement."
        }
        return nil
    }

    private static func triggerSummary(_ profile: DockProfile, displayNames: [String: String]) -> String {
        guard let requirements = profile.triggerRequirements, !requirements.isEmpty else {
            return "Not linked to any displays"
        }
        let names = requirements.keys
            .sorted { $0.storageKey < $1.storageKey }
            .map { displayNames[$0.storageKey] ?? "an unknown display" }
        return "Linked to " + ListFormatter.localizedString(byJoining: names)
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
