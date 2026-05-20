import Cocoa
import CoreGraphics
import os

// MARK: - Modifier key override option

enum ModifierOption: Int, CaseIterable, Codable, Sendable {
    case none    = 0
    case option  = 1
    case control = 2
    case shift   = 3
    case command = 4

    var label: String {
        switch self {
        case .none:    return "None"
        case .option:  return "Option (\u{2325})"
        case .control: return "Control (\u{2303})"
        case .shift:   return "Shift (\u{21E7})"
        case .command: return "Command (\u{2318})"
        }
    }

    var cgFlag: CGEventFlags? {
        switch self {
        case .none:    return nil
        case .option:  return .maskAlternate
        case .control: return .maskControl
        case .shift:   return .maskShift
        case .command: return .maskCommand
        }
    }
}

// MARK: - Cached screen geometry

struct DockTriggerZone: Sendable {
    let edge: DockEdge
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
    let triggerLine: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func nudgedPoint(from point: CGPoint) -> CGPoint {
        var nudged = point
        switch edge {
        case .bottom:
            nudged.y = triggerLine - 7
        case .left:
            nudged.x = triggerLine + 7
        case .right:
            nudged.x = triggerLine - 7
        }
        return nudged
    }
}

// MARK: - DockMonitor

@MainActor
final class DockMonitor {
    var allowedDisplays: Set<CGDirectDisplayID> = []
    var overrideModifier: ModifierOption = .option
    private(set) var isEnabled = false
    var onDockEdgeChanged: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPreferenceObserver: NSObjectProtocol?
    private nonisolated(unsafe) var stateLock = os_unfair_lock_s()
    private nonisolated(unsafe) var tapState = TapState()

    private struct TapState {
        var isEnabled = false
        var blockedZones: [DockTriggerZone] = []
        var cachedDockEdge: DockEdge = .bottom
        var overrideFlag: CGEventFlags? = CGEventFlags.maskAlternate
        var eventTap: CFMachPort?
    }

    // MARK: - Public

    @discardableResult
    func startLocking() -> Bool {
        guard !isEnabled else { return true }
        refreshScreenCache()
        if installEventTap() {
            isEnabled = true
            refreshScreenCache()
            startDockEdgeNotifications()
            return true
        }
        return false
    }

    func stopLocking() {
        guard isEnabled else { return }
        isEnabled = false
        stopDockEdgeNotifications()
        refreshScreenCache()
        removeEventTap()
    }

    func refreshScreenCache() {
        let dockEdge = DockEdge.current()
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        let snapshot = DisplaySnapshot.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(snapshot: snapshot, edge: dockEdge)
        let reachableAllowedDisplays = Set(allowedDisplays.filter { reachability[$0]?.isReachable == true })

        var nextState = TapState(
            isEnabled: isEnabled,
            blockedZones: [],
            cachedDockEdge: dockEdge,
            overrideFlag: overrideModifier.cgFlag,
            eventTap: eventTap
        )

        guard !reachableAllowedDisplays.isEmpty else {
            commitTapState(nextState)
            return
        }

        nextState.blockedZones = snapshot.filtered(for: .ignoreMirroredSecondaries)
            .filter { !reachableAllowedDisplays.contains($0.displayID) }
            .flatMap { descriptor -> [DockTriggerZone] in
                guard let info = reachability[descriptor.displayID] else { return [] }
                return info.exposedIntervals.map { interval in
                    zone(
                        for: descriptor.frame,
                        edge: dockEdge,
                        interval: interval,
                        primaryHeight: primaryH
                    )
                }
            }
        commitTapState(nextState)
    }

    private func zone(
        for frame: CGRect,
        edge: DockEdge,
        interval: EdgeInterval,
        primaryHeight: CGFloat
    ) -> DockTriggerZone {
        switch edge {
        case .bottom:
            let cgBottom = primaryHeight - frame.minY
            return DockTriggerZone(
                edge: .bottom,
                minX: interval.start,
                maxX: interval.end,
                minY: cgBottom - 5,
                maxY: cgBottom + 2,
                triggerLine: cgBottom
            )
        case .left:
            let cgMinY = primaryHeight - interval.end
            let cgMaxY = primaryHeight - interval.start
            return DockTriggerZone(
                edge: .left,
                minX: frame.minX - 2,
                maxX: frame.minX + 5,
                minY: cgMinY,
                maxY: cgMaxY,
                triggerLine: frame.minX
            )
        case .right:
            let cgMinY = primaryHeight - interval.end
            let cgMaxY = primaryHeight - interval.start
            return DockTriggerZone(
                edge: .right,
                minX: frame.maxX - 5,
                maxX: frame.maxX + 2,
                minY: cgMinY,
                maxY: cgMaxY,
                triggerLine: frame.maxX
            )
        }
    }

    // MARK: - Event Tap

    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        refreshScreenCache()
    }

    private func startDockEdgeNotifications() {
        guard dockPreferenceObserver == nil else { return }
        dockPreferenceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.dock.prefchanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                let previousEdge = self.currentTapState().cachedDockEdge
                self.refreshScreenCache()
                if DockEdge.current() != previousEdge {
                    self.onDockEdgeChanged?()
                }
            }
        }
    }

    private func stopDockEdgeNotifications() {
        if let observer = dockPreferenceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        dockPreferenceObserver = nil
    }

    private nonisolated(unsafe) func commitTapState(_ state: TapState) {
        os_unfair_lock_lock(&stateLock)
        tapState = state
        os_unfair_lock_unlock(&stateLock)
    }

    fileprivate nonisolated(unsafe) func currentTapState() -> TapState {
        os_unfair_lock_lock(&stateLock)
        let state = tapState
        os_unfair_lock_unlock(&stateLock)
        return state
    }

    fileprivate nonisolated(unsafe) func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        let state = currentTapState()

        // Re-enable if macOS auto-disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = state.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard state.isEnabled else { return Unmanaged.passUnretained(event) }

        if let flag = state.overrideFlag, event.flags.contains(flag) {
            return Unmanaged.passUnretained(event)
        }

        let loc = event.location

        for zone in state.blockedZones where zone.contains(loc) {
            event.location = zone.nudgedPoint(from: loc)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

}

// MARK: - C callback (no captures)

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.processEvent(event, type: type)
}
