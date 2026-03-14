import CoreGraphics

struct EdgeInterval: Sendable {
    var start: CGFloat
    var end: CGFloat

    init(start: CGFloat, end: CGFloat) {
        assert(end >= start, "EdgeInterval end must be >= start")
        self.start = start
        self.end = end
    }

    var length: CGFloat {
        assert(end >= start, "EdgeInterval end must be >= start")
        return end - start
    }
}

struct DisplayEdgeReachability: Sendable {
    var descriptor: DisplayDescriptor
    var edge: DockEdge
    var exposedIntervals: [EdgeInterval]

    var isReachable: Bool {
        exposedIntervals.contains(where: { $0.length > DisplayLayoutAnalyzer.minimumIntervalThreshold })
    }

    var longestExposedInterval: EdgeInterval? {
        exposedIntervals.max(by: { $0.length < $1.length })
    }

    var blockedReason: String {
        "\"\(descriptor.localizedName)\" can’t host the Dock on \(edge.label.lowercased()) because \(edge.blockedDirectionDescription)."
    }

    var preferredAppKitPoint: CGPoint? {
        guard let interval = longestExposedInterval else { return nil }

        switch edge {
        case .bottom:
            return CGPoint(
                x: interval.start + (interval.length / 2),
                y: descriptor.frame.minY + 1
            )
        case .left:
            return CGPoint(
                x: descriptor.frame.minX + 1,
                y: interval.start + (interval.length / 2)
            )
        case .right:
            return CGPoint(
                x: descriptor.frame.maxX - 1,
                y: interval.start + (interval.length / 2)
            )
        }
    }
}

enum DisplayLayoutAnalyzer {
    static let minimumIntervalThreshold: CGFloat = 0.5
    private static let adjacencyTolerance: CGFloat = 2

    static func reachabilityMap(
        snapshot: DisplaySnapshot,
        edge: DockEdge,
        mirroringPolicy: MirroringPolicy = .ignoreMirroredSecondaries
    ) -> [CGDirectDisplayID: DisplayEdgeReachability] {
        let displays = snapshot.filtered(for: mirroringPolicy)
        var result: [CGDirectDisplayID: DisplayEdgeReachability] = [:]
        for display in displays {
            result[display.displayID] = reachability(for: display, among: displays, edge: edge)
        }
        return result
    }

    private static func reachability(
        for target: DisplayDescriptor,
        among displays: [DisplayDescriptor],
        edge: DockEdge
    ) -> DisplayEdgeReachability {
        let total = axisInterval(for: target.frame, edge: edge)
        let covered = mergedIntervals(
            displays.compactMap { other in
                guard other.displayID != target.displayID else { return nil }
                guard isAdjacent(other.frame, blocking: target.frame, edge: edge) else { return nil }
                return overlappingInterval(target: target.frame, other: other.frame, edge: edge)
            }
        )

        return DisplayEdgeReachability(
            descriptor: target,
            edge: edge,
            exposedIntervals: subtract(covered: covered, from: total)
        )
    }

    private static func axisInterval(for frame: CGRect, edge: DockEdge) -> EdgeInterval {
        switch edge {
        case .bottom:
            return EdgeInterval(start: frame.minX, end: frame.maxX)
        case .left, .right:
            return EdgeInterval(start: frame.minY, end: frame.maxY)
        }
    }

    private static func isAdjacent(_ other: CGRect, blocking target: CGRect, edge: DockEdge) -> Bool {
        switch edge {
        case .bottom:
            return abs(other.maxY - target.minY) <= adjacencyTolerance
        case .left:
            return abs(other.maxX - target.minX) <= adjacencyTolerance
        case .right:
            return abs(other.minX - target.maxX) <= adjacencyTolerance
        }
    }

    private static func overlappingInterval(target: CGRect, other: CGRect, edge: DockEdge) -> EdgeInterval? {
        let start: CGFloat
        let end: CGFloat

        switch edge {
        case .bottom:
            start = max(target.minX, other.minX)
            end = min(target.maxX, other.maxX)
        case .left, .right:
            start = max(target.minY, other.minY)
            end = min(target.maxY, other.maxY)
        }

        guard end - start > minimumIntervalThreshold else { return nil }
        return EdgeInterval(start: start, end: end)
    }

    private static func mergedIntervals(_ intervals: [EdgeInterval]) -> [EdgeInterval] {
        let sorted = intervals.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        guard var current = sorted.first else { return [] }

        var result: [EdgeInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end + minimumIntervalThreshold {
                current.end = max(current.end, interval.end)
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private static func subtract(covered: [EdgeInterval], from total: EdgeInterval) -> [EdgeInterval] {
        guard total.length > minimumIntervalThreshold else { return [] }
        guard !covered.isEmpty else { return [total] }

        let covered = covered.sorted { $0.start < $1.start }
        var cursor = total.start
        var result: [EdgeInterval] = []

        for interval in covered {
            if interval.end <= cursor { continue }
            if interval.start > cursor {
                result.append(EdgeInterval(start: cursor, end: min(interval.start, total.end)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= total.end {
                break
            }
        }

        if cursor < total.end {
            result.append(EdgeInterval(start: cursor, end: total.end))
        }

        return result.filter { $0.length > minimumIntervalThreshold }
    }
}
