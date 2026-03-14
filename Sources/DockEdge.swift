import Foundation

enum DockEdge: String, CaseIterable, Codable, Sendable {
    case left
    case bottom
    case right

    private static let dockDefaults = UserDefaults(suiteName: "com.apple.dock")

    static func current() -> DockEdge {
        guard
            let raw = dockDefaults?.string(forKey: "orientation")?.lowercased(),
            let edge = DockEdge(rawValue: raw)
        else {
            return .bottom
        }
        return edge
    }

    var label: String {
        rawValue.capitalized
    }

    var blockedDirectionDescription: String {
        switch self {
        case .bottom:
            return "another display is directly below it"
        case .left:
            return "another display is directly to its left"
        case .right:
            return "another display is directly to its right"
        }
    }

    var requirementDescription: String {
        "\(rawValue) edge"
    }
}
