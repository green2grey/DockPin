import AppKit
import CoreGraphics

/// Best-effort relocation of the Dock. macOS moves the Dock to a display when the pointer is
/// pushed against that display's Dock edge, so this glides the cursor to the edge, keeps
/// "pushing" until the Dock arrives, and puts the cursor back.
@MainActor
final class DockReanchorer {
    enum Mode: Sendable {
        /// The user asked from the menu: always make at least one attempt.
        case manual
        /// DockPin is checking on its own: only take the cursor when the Dock is known to be elsewhere.
        case automatic
    }

    /// Everything the re-anchor touches outside itself, so the sequencing can be tested without
    /// moving a real cursor.
    @MainActor
    struct Environment {
        var dockLocation: @MainActor () -> DockLocation
        /// Cursor position in AppKit (bottom-left origin) coordinates.
        var cursorLocation: @MainActor () -> CGPoint
        /// Puts the cursor at a point and reports it to the system as mouse movement by `delta`.
        /// Both are in AppKit coordinates.
        var moveCursor: @MainActor (_ point: CGPoint, _ delta: CGVector) -> Void
        var isMouseButtonDown: @MainActor () -> Bool
        var sleep: @MainActor (Duration) async throws -> Void

        static var live: Environment {
            Environment(
                dockLocation: { DockLocator.current() },
                cursorLocation: { NSEvent.mouseLocation },
                moveCursor: { DockReanchorer.warpAndPost(to: $0, delta: $1) },
                isMouseButtonDown: {
                    [CGMouseButton.left, .right, .center].contains {
                        CGEventSource.buttonState(.combinedSessionState, button: $0)
                    }
                },
                sleep: { @MainActor duration in try await Task.sleep(for: duration) }
            )
        }
    }

    /// The shape of the gesture.
    ///
    /// A single event at the edge followed by a silent hold does not move the Dock on current
    /// macOS; it wants to keep seeing movement while the pointer sits on the edge. So the cursor
    /// glides in over `approachDistance`, then a movement event is sent every `pushInterval` until
    /// the Dock shows up on the target display or `maximumPush` runs out.
    struct Gesture: Equatable, Sendable {
        var approachDistance: CGFloat = 50
        var approachSteps = 8
        var approachStepDelay: Duration = .milliseconds(15)
        var pushInterval: Duration = .milliseconds(20)
        var maximumPush: Duration = .milliseconds(1200)
        /// Movement reported per push, pointing out through the edge.
        var pushDelta: CGFloat = 6
        /// How many pushes go by between looks at where the Dock is.
        var pushesPerLocationCheck = 5

        static let standard = Gesture()
    }

    static let maximumAttempts = 3
    private static let retryDelay: Duration = .seconds(2)
    private static let buttonPollInterval: Duration = .milliseconds(250)
    private static let buttonWaitLimit: Duration = .seconds(10)

    private let environment: Environment
    private var task: Task<Void, Never>?
    /// Bumped on every cancel so a superseded run can tell it no longer owns the cursor.
    private var generation = 0
    /// Where the user's cursor was before DockPin moved it; nil while DockPin isn't holding it.
    private var savedCursorPosition: CGPoint?

    init(environment: Environment? = nil) {
        self.environment = environment ?? .live
    }

    var isRunning: Bool { task != nil }

    /// Stops any attempt in flight and returns the cursor to where the user left it.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        restoreCursor()
    }

    /// Starts a re-anchor, replacing any attempt in flight.
    ///
    /// `target` is asked again before every attempt, so a display, profile or permission change
    /// between attempts is picked up; returning nil ends the run.
    func reanchor(mode: Mode, target: @escaping @MainActor () -> DisplayEdgeReachability?) {
        cancel()
        let run = generation
        task = Task { @MainActor [weak self] in
            await self?.perform(mode: mode, run: run, target: target)
            guard let self, self.generation == run else { return }
            self.restoreCursor()
            self.task = nil
        }
    }

    private func perform(
        mode: Mode,
        run: Int,
        target: @MainActor () -> DisplayEdgeReachability?
    ) async {
        var attempts = 0

        while attempts < Self.maximumAttempts {
            guard isCurrent(run),
                  let reachability = target(),
                  let point = reachability.preferredAppKitPoint
            else { return }

            let targetDisplay = reachability.descriptor.displayID
            let isForcedAttempt = (mode == .manual && attempts == 0)

            if !isForcedAttempt {
                switch environment.dockLocation() {
                case .display(let current) where current == targetDisplay:
                    return
                case .display:
                    break
                case .hidden:
                    // A hidden Dock appears wherever it is summoned, and blocking already limits
                    // that to allowed displays. Nothing to gain from taking the cursor.
                    return
                case .unknown:
                    // No way to confirm the result, so one blind attempt is the most we make.
                    if attempts > 0 { return }
                }
            }

            guard await waitForMouseButtonsUp(run: run) else { return }

            if savedCursorPosition == nil {
                savedCursorPosition = environment.cursorLocation()
            }
            let outcome = await push(
                toward: point,
                edge: reachability.edge,
                targetDisplay: targetDisplay,
                gesture: Self.currentGesture,
                run: run
            )
            guard outcome != .interrupted else { return }
            restoreCursor()
            attempts += 1
            if outcome == .arrived { return }

            switch environment.dockLocation() {
            case .display(let current) where current == targetDisplay:
                return
            case .display:
                // Still confirmed elsewhere: give macOS a moment, then look again.
                guard attempts < Self.maximumAttempts,
                      await pause(Self.retryDelay, run: run)
                else { return }
            case .hidden, .unknown:
                return
            }
        }
    }

    private enum PushOutcome {
        /// The Dock was seen on the target display.
        case arrived
        /// The time ran out without seeing it there.
        case timedOut
        /// The run was cancelled or replaced; the cursor is no longer ours to touch.
        case interrupted
    }

    private func push(
        toward point: CGPoint,
        edge: DockEdge,
        targetDisplay: CGDirectDisplayID,
        gesture: Gesture,
        run: Int
    ) async -> PushOutcome {
        var previous: CGPoint?
        for step in Self.approachPath(to: point, edge: edge, gesture: gesture) {
            let delta = previous.map { CGVector(dx: step.x - $0.x, dy: step.y - $0.y) } ?? .zero
            environment.moveCursor(step, delta)
            previous = step
            guard await pause(gesture.approachStepDelay, run: run) else { return .interrupted }
        }

        let outward = Self.outwardDirection(for: edge)
        let pushDelta = CGVector(dx: outward.dx * gesture.pushDelta, dy: outward.dy * gesture.pushDelta)
        var pushed: Duration = .zero
        var pushes = 0

        while pushed < gesture.maximumPush {
            environment.moveCursor(point, pushDelta)
            guard await pause(gesture.pushInterval, run: run) else { return .interrupted }
            pushed += gesture.pushInterval
            pushes += 1

            if pushes % max(1, gesture.pushesPerLocationCheck) == 0,
               case .display(let current) = environment.dockLocation(), current == targetDisplay {
                return .arrived
            }
        }
        return .timedOut
    }

    /// Waits for the user to finish a click or drag. Returns false when the run should stop.
    private func waitForMouseButtonsUp(run: Int) async -> Bool {
        var waited: Duration = .zero
        while environment.isMouseButtonDown() {
            guard waited < Self.buttonWaitLimit,
                  await pause(Self.buttonPollInterval, run: run)
            else { return false }
            waited += Self.buttonPollInterval
        }
        return isCurrent(run)
    }

    private func pause(_ duration: Duration, run: Int) async -> Bool {
        do {
            try await environment.sleep(duration)
        } catch {
            return false
        }
        return isCurrent(run)
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !Task.isCancelled
    }

    private func restoreCursor() {
        guard let original = savedCursorPosition else { return }
        savedCursorPosition = nil
        environment.moveCursor(original, .zero)
    }

    // MARK: - Geometry (AppKit coordinates)

    /// Unit vector pointing off the display through its Dock edge.
    static func outwardDirection(for edge: DockEdge) -> CGVector {
        switch edge {
        case .bottom: return CGVector(dx: 0, dy: -1)
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        }
    }

    /// Evenly spaced points from `approachDistance` inside the display up to `point` on its edge.
    static func approachPath(to point: CGPoint, edge: DockEdge, gesture: Gesture = .standard) -> [CGPoint] {
        let outward = outwardDirection(for: edge)
        let steps = max(2, gesture.approachSteps)
        return (0..<steps).map { index in
            let remaining = gesture.approachDistance * (1 - CGFloat(index) / CGFloat(steps - 1))
            return CGPoint(x: point.x - outward.dx * remaining, y: point.y - outward.dy * remaining)
        }
    }

    // MARK: - Live cursor control

    private static let eventSource = CGEventSource(stateID: .hidSystemState)

    private static func warpAndPost(to appKitPoint: CGPoint, delta: CGVector) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
        CGWarpMouseCursorPosition(quartzPoint)
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else { return }
        // Quartz y grows downward, AppKit y upward.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((-delta.dy).rounded()))
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Gesture selection

    /// The gesture to use. Release builds always use the standard one; a dev build
    /// (`build-dev.sh`) can override individual values from its own defaults domain so timings
    /// can be tried against the real Dock without rebuilding, for example:
    /// `defaults write com.green2grey.DockPin.dev dev.gesture.maximumPushMs -int 2000`
    private static var currentGesture: Gesture {
        #if DOCKPIN_DEV
        var gesture = Gesture.standard
        let defaults = UserDefaults.standard
        func number(_ key: String) -> Double? {
            (defaults.object(forKey: "dev.gesture.\(key)") as? NSNumber)?.doubleValue
        }
        if let value = number("approachDistance") { gesture.approachDistance = value }
        if let value = number("approachSteps") { gesture.approachSteps = Int(value) }
        if let value = number("approachStepDelayMs") { gesture.approachStepDelay = .milliseconds(Int(value)) }
        if let value = number("pushIntervalMs") { gesture.pushInterval = .milliseconds(max(1, Int(value))) }
        if let value = number("maximumPushMs") { gesture.maximumPush = .milliseconds(Int(value)) }
        if let value = number("pushDelta") { gesture.pushDelta = value }
        if let value = number("pushesPerLocationCheck") { gesture.pushesPerLocationCheck = Int(value) }
        return gesture
        #else
        return .standard
        #endif
    }
}
