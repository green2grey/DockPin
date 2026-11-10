import Foundation

/// What DockPin is actually doing right now, as opposed to what the active profile asks for.
enum LockStatus: Equatable, Sendable {
    case notConfigured
    /// The active profile is switched off.
    case disabled
    /// The event tap is installed and blocking.
    case locking
    /// The profile is on, but macOS hasn't granted (or has withdrawn) Accessibility access.
    case needsAccessibility
    /// "Displays have separate Spaces" is off, so macOS keeps the Dock on the main display.
    case separateSpacesOff
    /// None of the profile's allowed displays is connected.
    case allowedDisplayMissing
    /// Allowed displays are connected, but none exposes the current Dock edge.
    case edgeBlocked
    /// Everything checks out, yet the event tap could not be created.
    case tapUnavailable

    static func evaluate(
        isConfigured: Bool,
        profileEnabled: Bool,
        isTrusted: Bool,
        hasSeparateSpaces: Bool,
        hasAllowedDisplay: Bool,
        hasReachableAllowedDisplay: Bool,
        isLocking: Bool
    ) -> LockStatus {
        guard isConfigured else { return .notConfigured }
        guard profileEnabled else { return .disabled }
        guard isTrusted else { return .needsAccessibility }
        guard hasSeparateSpaces else { return .separateSpacesOff }
        guard hasAllowedDisplay else { return .allowedDisplayMissing }
        guard hasReachableAllowedDisplay else { return .edgeBlocked }
        return isLocking ? .locking : .tapUnavailable
    }

    /// Whether the conditions for installing the event tap are met.
    var permitsLocking: Bool {
        self == .locking || self == .tapUnavailable
    }

    /// The profile is on and DockPin can't do its job until the user acts.
    var needsAttention: Bool {
        self == .needsAccessibility || self == .tapUnavailable
    }

    /// One line for the menu explaining why an enabled profile isn't blocking; nil when there is
    /// nothing to explain.
    func explanation(dockEdge: DockEdge) -> String? {
        switch self {
        case .notConfigured, .disabled, .locking:
            return nil
        case .needsAccessibility:
            return "Accessibility access needed"
        case .separateSpacesOff:
            return "Off: “Displays have separate Spaces” is disabled"
        case .allowedDisplayMissing:
            return "Idle: no allowed display connected"
        case .edgeBlocked:
            return "Idle: \(dockEdge.requirementDescription) blocked on allowed displays"
        case .tapUnavailable:
            return "Couldn’t start blocking — try relaunching DockPin"
        }
    }
}
