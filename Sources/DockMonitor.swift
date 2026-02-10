import Cocoa
import CoreGraphics

// MARK: - Modifier key override option

enum ModifierOption: Int, CaseIterable {
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

struct ScreenBounds {
    let cgLeft:   CGFloat
    let cgRight:  CGFloat
    let cgBottom: CGFloat   // bottom edge in CG coordinates (origin top-left, Y increases down)
}

// MARK: - DockMonitor

final class DockMonitor {

    /// Displays where the Dock is allowed.
    var allowedDisplays: Set<CGDirectDisplayID> = []

    /// Modifier key that temporarily disables locking.
    var overrideModifier: ModifierOption = .option

    /// Whether locking is active.
    private(set) var isEnabled = false

    // Internals
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Screen bounds for blocked displays (written on main thread, read in callback).
    fileprivate var blockedScreens: [ScreenBounds] = []
    fileprivate var overrideFlag: CGEventFlags? = CGEventFlags.maskAlternate

    // MARK: - Persistence

    func saveState() {
        let ids = allowedDisplays.map { Int($0) }
        UserDefaults.standard.set(ids, forKey: "allowedDisplays")
        UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
        UserDefaults.standard.set(overrideModifier.rawValue, forKey: "overrideModifier")
    }

    func restoreState() {
        if let ids = UserDefaults.standard.array(forKey: "allowedDisplays") as? [Int] {
            allowedDisplays = Set(ids.map { CGDirectDisplayID($0) })
        }
        isEnabled = UserDefaults.standard.bool(forKey: "isEnabled")
        overrideModifier = ModifierOption(rawValue: UserDefaults.standard.integer(forKey: "overrideModifier")) ?? .option
        overrideFlag = overrideModifier.cgFlag
    }

    // MARK: - Public

    /// Returns `true` if locking started successfully, `false` if the event tap failed.
    @discardableResult
    func startLocking() -> Bool {
        guard !isEnabled else { return true }
        overrideFlag = overrideModifier.cgFlag
        refreshScreenCache()
        if installEventTap() {
            isEnabled = true
            return true
        }
        return false
    }

    func stopLocking() {
        guard isEnabled else { return }
        isEnabled = false
        removeEventTap()
    }

    /// Recompute cached bounds for all non-allowed screens.
    func refreshScreenCache() {
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        blockedScreens = NSScreen.screens
            .filter { !allowedDisplays.contains($0.displayID) }
            .map { s in
                let f = s.frame
                return ScreenBounds(
                    cgLeft:   f.minX,
                    cgRight:  f.maxX,
                    cgBottom: primaryH - f.minY
                )
            }
        overrideFlag = overrideModifier.cgFlag
    }

    // MARK: - Event Tap

    /// Returns `true` if the tap was installed, `false` on failure (no Accessibility permission).
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
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    /// Core event processing – invoked from the C callback.
    fileprivate func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Re-enable if macOS auto-disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled else { return Unmanaged.passUnretained(event) }

        // Allow free movement while override modifier is held
        if let flag = overrideFlag, event.flags.contains(flag) {
            return Unmanaged.passUnretained(event)
        }

        let loc = event.location

        for s in blockedScreens {
            guard loc.x >= s.cgLeft, loc.x < s.cgRight else { continue }

            // Within 5 px of the bottom edge → nudge cursor up
            if loc.y >= s.cgBottom - 5 && loc.y <= s.cgBottom + 2 {
                var nudged = loc
                nudged.y = s.cgBottom - 7
                event.location = nudged
                return Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Helpers

    /// Detect which screen currently hosts the Dock (bottom-positioned only).
    static func currentDockScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let gap = screen.visibleFrame.minY - screen.frame.minY
            return gap > 10
        }
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
