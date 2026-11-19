import Foundation

enum DockEdge: String, CaseIterable, Codable, Sendable {
    case left
    case bottom
    case right

    fileprivate static let dockDefaults = UserDefaults(suiteName: "com.apple.dock")

    static func current() -> DockEdge {
        guard
            let raw = dockDefaults?.string(forKey: "orientation")?.lowercased(),
            let edge = DockEdge(rawValue: raw)
        else {
            return .bottom
        }
        return edge
    }

    /// The edge's name on its own, as a label: "Bottom" / "底".
    var label: String {
        switch self {
        case .left: return L("Left")
        case .bottom: return L("Bottom")
        case .right: return L("Right")
        }
    }

    /// The edge's name inside a sentence: "a free bottom edge" / "底".
    var nameInSentence: String {
        switch self {
        case .left: return L("left")
        case .bottom: return L("bottom")
        case .right: return L("right")
        }
    }

    var blockedDirectionDescription: String {
        switch self {
        case .bottom:
            return L("another display is directly below it")
        case .left:
            return L("another display is directly to its left")
        case .right:
            return L("another display is directly to its right")
        }
    }

    var requirementDescription: String {
        L("%@ edge", nameInSentence)
    }
}

/// Other Dock settings DockPin reads (never writes).
enum DockPreferences {
    static var isAutoHideEnabled: Bool {
        DockEdge.dockDefaults?.bool(forKey: "autohide") ?? false
    }
}
