import AppKit
import CoreGraphics

/// Which display the Dock is on, as far as DockPin can tell.
enum DockLocation: Equatable, Sendable {
    case display(CGDirectDisplayID)
    /// The Dock auto-hides and no display could be identified for it.
    case hidden
    /// Detection failed for some other reason (Dock restarting, unexpected window layout).
    case unknown
}

/// Finds the Dock's display from the window server and screen geometry.
///
/// This deliberately avoids the Accessibility API: those calls are synchronous round trips to the
/// Dock process, and DockPin's event tap is serviced on the same (main) thread.
enum DockLocator {
    typealias Display = (id: CGDirectDisplayID, bounds: CGRect)
    typealias Screen = (id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect)

    private static let dockBundleIdentifier = "com.apple.dock"
    /// A window counts as being "on" a display when at least this share of it lies inside.
    private static let containmentThreshold: CGFloat = 0.9
    /// Smallest edge inset that can only be a visible Dock.
    private static let minimumDockInset: CGFloat = 8

    @MainActor
    static func current(snapshot: DisplaySnapshot = .current(), edge: DockEdge = .current()) -> DockLocation {
        let displays: [Display] = snapshot.filtered(for: .ignoreMirroredSecondaries).map {
            (id: $0.displayID, bounds: CGDisplayBounds($0.displayID))
        }
        if let id = display(forDockWindows: dockWindowBounds(), displays: displays) {
            return .display(id)
        }

        let screens: [Screen] = NSScreen.screens.compactMap { screen in
            guard let id = screen.dockPinDisplayID else { return nil }
            return (id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        if let id = displayWithDockInset(screens: screens, edge: edge) {
            return .display(id)
        }

        return DockPreferences.isAutoHideEnabled ? .hidden : .unknown
    }

    /// Bounds (global, top-left origin) of the Dock's own on-screen windows at Dock level.
    static func dockWindowBounds() -> [CGRect] {
        let dockPIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleIdentifier)
                .map(\.processIdentifier)
        )
        guard !dockPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        return windows.compactMap { info in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == dockLevel,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, dockPIDs.contains(pid),
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            return bounds
        }
    }

    /// The single display that holds every Dock window, or nil when that is ambiguous.
    ///
    /// On current macOS the Dock owns one Dock-level window covering the whole display it lives on;
    /// the rule also holds for a bar-sized window.
    static func display(forDockWindows windows: [CGRect], displays: [Display]) -> CGDirectDisplayID? {
        var matches: Set<CGDirectDisplayID> = []

        for window in windows {
            let windowArea = window.width * window.height
            guard windowArea > 0 else { continue }

            let best = displays
                .map { display -> (id: CGDirectDisplayID, overlap: CGFloat) in
                    let intersection = display.bounds.intersection(window)
                    let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                    return (id: display.id, overlap: overlap)
                }
                .max { $0.overlap < $1.overlap }

            guard let best, best.overlap >= windowArea * containmentThreshold else { continue }
            matches.insert(best.id)
        }

        return matches.count == 1 ? matches.first : nil
    }

    /// The single screen whose usable area is inset on the Dock edge, or nil. Only a visible Dock
    /// reserves space there, so this finds nothing while the Dock is hidden.
    static func displayWithDockInset(screens: [Screen], edge: DockEdge) -> CGDirectDisplayID? {
        let matches = screens.filter { screen in
            let inset: CGFloat
            switch edge {
            case .bottom: inset = screen.visibleFrame.minY - screen.frame.minY
            case .left: inset = screen.visibleFrame.minX - screen.frame.minX
            case .right: inset = screen.frame.maxX - screen.visibleFrame.maxX
            }
            return inset >= minimumDockInset
        }
        return matches.count == 1 ? matches.first?.id : nil
    }
}
