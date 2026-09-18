import AppKit
import CoreGraphics

@MainActor
final class DockReanchorer {
    private var task: Task<Void, Never>?
    private var originalCursorPosition: CGPoint?
    private var generation = 0

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        restoreCursor()
    }

    func reanchor(target: @escaping @MainActor () -> DisplayEdgeReachability?) {
        cancel()
        let startedGeneration = generation
        task = Task { @MainActor in
            defer {
                if self.generation == startedGeneration {
                    self.restoreCursor()
                    self.task = nil
                }
            }
            let source = CGEventSource(stateID: .combinedSessionState)

            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                guard AXIsProcessTrusted(), let reachability = target(),
                      let point = reachability.preferredAppKitPoint else { return }
                if Self.dockIsOnDisplay(reachability.descriptor.displayID) { return }

                self.originalCursorPosition = NSEvent.mouseLocation
                for point in self.approachPoints(for: point, edge: reachability.edge) {
                    guard !Task.isCancelled else { return }
                    Self.warpAndPost(to: point, source: source)
                    do {
                        try await Task.sleep(for: .milliseconds(70))
                    } catch {
                        return
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let relocated = Self.dockIsOnDisplay(reachability.descriptor.displayID)
                self.restoreCursor()
                if relocated { return }
                if attempt < 2 {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func restoreCursor() {
        guard let original = originalCursorPosition else { return }
        originalCursorPosition = nil
        Self.warpAndPost(to: original, source: CGEventSource(stateID: .combinedSessionState))
    }

    private static func dockIsOnDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return false }
        for element in elements {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXListRole else { continue }
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent),
                  extent.width > 0, extent.height > 0 else { continue }
            let center = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
            if CGDisplayBounds(displayID).contains(center) { return true }
        }
        return false
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
