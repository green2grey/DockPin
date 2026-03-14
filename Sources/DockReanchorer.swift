import AppKit
import CoreGraphics

@MainActor
final class DockReanchorer {
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reanchor(to reachability: DisplayEdgeReachability) {
        guard let target = reachability.preferredAppKitPoint else { return }

        let original = NSEvent.mouseLocation
        let sequence = approachPoints(for: target, edge: reachability.edge)

        cancel()
        task = Task { @MainActor [sequence, original] in
            defer { self.task = nil }
            let source = CGEventSource(stateID: .combinedSessionState)
            defer { Self.warpAndPost(to: original, source: source) }

            for point in sequence {
                if Task.isCancelled { return }
                Self.warpAndPost(to: point, source: source)
                try? await Task.sleep(for: .milliseconds(70))
                if Task.isCancelled { return }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func approachPoints(for point: CGPoint, edge: DockEdge) -> [CGPoint] {
        switch edge {
        case .bottom:
            return [
                CGPoint(x: point.x, y: point.y + 18),
                CGPoint(x: point.x, y: point.y + 4),
                point,
            ]
        case .left:
            return [
                CGPoint(x: point.x + 18, y: point.y),
                CGPoint(x: point.x + 4, y: point.y),
                point,
            ]
        case .right:
            return [
                CGPoint(x: point.x - 18, y: point.y),
                CGPoint(x: point.x - 4, y: point.y),
                point,
            ]
        }
    }

    private static func warpAndPost(to appKitPoint: CGPoint, source: CGEventSource?) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
        CGWarpMouseCursorPosition(quartzPoint)
        if let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }
}
