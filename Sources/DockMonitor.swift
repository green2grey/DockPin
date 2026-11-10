import Cocoa
import CoreGraphics

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

struct DockTriggerZone {
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

final class DockMonitor {
    private static let healthCheckInterval: TimeInterval = 0.5

    var allowedDisplays: Set<CGDirectDisplayID> = []
    var overrideModifier: ModifierOption = .option
    private(set) var isEnabled = false

    /// Called on the main thread after the monitor has shut its event tap down because
    /// Accessibility access went away.
    var onAccessibilityLost: (() -> Void)?
    /// Replaceable in tests.
    var isProcessTrusted: () -> Bool = { AXIsProcessTrusted() }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    // The tap's run-loop source is added to the main run loop, so the callback, the health timer
    // and every writer of the state below all run on the main thread.
    fileprivate var blockedZones: [DockTriggerZone] = []
    fileprivate var cachedDockEdge: DockEdge = .bottom
    fileprivate var overrideFlag: CGEventFlags? = CGEventFlags.maskAlternate
    /// System uptime of the last event the override modifier let through a blocked zone.
    private var lastOverrideBypassUptime: TimeInterval?

    // MARK: - Public

    @discardableResult
    func startLocking() -> Bool {
        guard !isEnabled else { return true }
        overrideFlag = overrideModifier.cgFlag
        refreshScreenCache()
        if installEventTap() {
            isEnabled = true
            startHealthChecks()
            return true
        }
        return false
    }

    func stopLocking() {
        guard isEnabled else { return }
        isEnabled = false
        stopHealthChecks()
        removeEventTap()
    }

    /// Whether the user recently used the override modifier to push through a blocked Dock edge,
    /// which means a Dock move right now is theirs and not macOS acting on its own.
    func overrideBypassed(within interval: TimeInterval) -> Bool {
        guard let last = lastOverrideBypassUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - last <= interval
    }

    /// Whether the override modifier is physically held right now.
    var isOverrideModifierDown: Bool {
        guard let flag = overrideModifier.cgFlag else { return false }
        return CGEventSource.flagsState(.combinedSessionState).contains(flag)
    }

    func refreshScreenCache() {
        let dockEdge = DockEdge.current()
        cachedDockEdge = dockEdge
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        let snapshot = DisplaySnapshot.current()
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(snapshot: snapshot, edge: dockEdge)
        let reachableAllowedDisplays = Set(allowedDisplays.filter { reachability[$0]?.isReachable == true })

        guard !reachableAllowedDisplays.isEmpty else {
            blockedZones = []
            overrideFlag = overrideModifier.cgFlag
            return
        }

        blockedZones = snapshot.filtered(for: .ignoreMirroredSecondaries)
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
        overrideFlag = overrideModifier.cgFlag
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
    }

    // MARK: - Health checks

    private func startHealthChecks() {
        guard healthCheckTimer == nil else { return }

        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            self?.runHealthCheck()
        }
        healthCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func runHealthCheck() {
        guard isEnabled else { return }

        // An active tap held by a process that has lost Accessibility access can stall mouse
        // input for the whole session, so this is checked before anything else.
        guard isProcessTrusted() else {
            handleAccessibilityLost()
            return
        }

        // macOS can switch a tap off (after a timeout, across sleep) without the callback
        // hearing about it; without this DockPin would silently stop blocking.
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if DockEdge.current() != cachedDockEdge {
            refreshScreenCache()
        }
    }

    private func handleAccessibilityLost() {
        guard isEnabled else { return }
        stopLocking()
        onAccessibilityLost?()
    }

    // MARK: - Event handling

    fileprivate func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS auto-disabled the tap; turn it back on, but never re-arm a filter we're no
            // longer allowed to run. In that case the tap stays off and the next health check
            // (at most half a second away) tears it down, outside its own callback.
            if isProcessTrusted(), let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if let flag = overrideFlag, event.flags.contains(flag) {
            let loc = event.location
            if blockedZones.contains(where: { $0.contains(loc) }) {
                lastOverrideBypassUptime = ProcessInfo.processInfo.systemUptime
            }
            return Unmanaged.passUnretained(event)
        }

        let loc = event.location

        for zone in blockedZones where zone.contains(loc) {
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
