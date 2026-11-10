import CoreGraphics
import Testing
@testable import DockPin

private let targetDisplay: CGDirectDisplayID = 1
private let otherDisplay: CGDirectDisplayID = 2
private let userCursor = CGPoint(x: 500, y: 500)

/// A Dock edge on display 1 to aim for.
private let target = DisplayEdgeReachability(
    descriptor: DisplayDescriptor(
        displayID: targetDisplay,
        stableID: DisplayStableID(vendorID: 1, modelID: 1, serial: 1),
        localizedName: "Target",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        isBuiltIn: false,
        isMirroredSecondary: false
    ),
    edge: .bottom,
    exposedIntervals: [EdgeInterval(start: 0, end: 1920)]
)
private let edgePoint = CGPoint(x: 960, y: 1)
/// Where a glide toward that edge begins; the cursor visits it once per gesture.
private let approachStart = CGPoint(x: 960, y: 51)

/// Stands in for the cursor, the Dock and the clock.
@MainActor
private final class FakeWorld {
    var dockLocation: DockLocation
    var cursor = userCursor
    var moves: [CGPoint] = []
    var deltas: [CGVector] = []
    var buttonDown = false
    var sleeps: [Duration] = []
    /// Runs at the start of every sleep with that sleep's 1-based index, so a test can act at an
    /// exact point in the sequence.
    var onSleep: ((Int) -> Void)?
    /// When set, the Dock "moves" to this display as soon as the cursor reaches the Dock edge.
    var dockFollowsCursorTo: CGDirectDisplayID?

    init(dock: DockLocation) {
        dockLocation = dock
    }

    var environment: DockReanchorer.Environment {
        DockReanchorer.Environment(
            dockLocation: { self.dockLocation },
            cursorLocation: { self.cursor },
            moveCursor: { point, delta in
                self.moves.append(point)
                self.deltas.append(delta)
                self.cursor = point
                if point == edgePoint, let display = self.dockFollowsCursorTo {
                    self.dockLocation = .display(display)
                }
            },
            isMouseButtonDown: { self.buttonDown },
            sleep: { duration in
                self.sleeps.append(duration)
                self.onSleep?(self.sleeps.count)
                await Task.yield()
                try Task.checkCancellation()
            }
        )
    }

    /// Number of times the cursor was sent toward the Dock edge.
    var gestures: Int { moves.filter { $0 == approachStart }.count }
    /// Number of movement events reported with the cursor on the Dock edge.
    var eventsOnEdge: Int { moves.filter { $0 == edgePoint }.count }
}

@MainActor
private func finish(_ reanchorer: DockReanchorer) async {
    var turns = 0
    while reanchorer.isRunning, turns < 10_000 {
        await Task.yield()
        turns += 1
    }
    #expect(!reanchorer.isRunning, "re-anchor never finished")
}

@MainActor
@Suite struct DockReanchorerTests {
    @Test func automaticLeavesTheCursorAloneWhenTheDockIsAlreadyThere() async {
        let world = FakeWorld(dock: .display(targetDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.moves.isEmpty)
    }

    @Test func automaticMovesTheDockOnceAndPutsTheCursorBack() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        world.dockFollowsCursorTo = targetDisplay
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.gestures == 1)
        #expect(world.cursor == userCursor)
        #expect(world.dockLocation == .display(targetDisplay))
    }

    // What macOS 27 needs: one event on the edge followed by a silent hold moves nothing. The
    // cursor has to keep reporting movement for as long as it sits there.
    @Test func keepsReportingMovementWhileOnTheEdge() async {
        let world = FakeWorld(dock: .unknown)
        let reanchorer = DockReanchorer(environment: world.environment)
        let gesture = DockReanchorer.Gesture.standard

        reanchorer.reanchor(mode: .manual) { target }
        await finish(reanchorer)

        let expectedPushes = Int(gesture.maximumPush / gesture.pushInterval)
        #expect(expectedPushes >= 30)
        // The glide ends on the edge, then every push is another event there.
        #expect(world.eventsOnEdge == expectedPushes + 1)
        // Each push reports movement out through the bottom edge (downward in AppKit terms).
        let pushDeltas = zip(world.moves, world.deltas).filter { $0.0 == edgePoint }.dropFirst().map(\.1)
        #expect(pushDeltas.allSatisfy { $0 == CGVector(dx: 0, dy: -gesture.pushDelta) })
    }

    @Test func stopsPushingAsSoonAsTheDockArrives() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        world.dockFollowsCursorTo = targetDisplay
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        // One event from the glide plus the pushes up to the first look at the Dock.
        #expect(world.eventsOnEdge == 1 + DockReanchorer.Gesture.standard.pushesPerLocationCheck)
        #expect(world.cursor == userCursor)
    }

    @Test func glidesInFromInsideTheDisplay() {
        let bottom = DockReanchorer.approachPath(to: CGPoint(x: 960, y: 1), edge: .bottom)
        #expect(bottom.first == CGPoint(x: 960, y: 51))
        #expect(bottom.last == CGPoint(x: 960, y: 1))
        #expect(bottom.count == DockReanchorer.Gesture.standard.approachSteps)
        #expect(zip(bottom, bottom.dropFirst()).allSatisfy { $0.y > $1.y })

        let left = DockReanchorer.approachPath(to: CGPoint(x: 1, y: 500), edge: .left)
        #expect(left.first == CGPoint(x: 51, y: 500))
        #expect(left.last == CGPoint(x: 1, y: 500))

        let right = DockReanchorer.approachPath(to: CGPoint(x: 1919, y: 500), edge: .right)
        #expect(right.first == CGPoint(x: 1869, y: 500))
        #expect(right.last == CGPoint(x: 1919, y: 500))
    }

    @Test func givesUpAfterThreeAttemptsWhenTheDockWillNotMove() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.gestures == DockReanchorer.maximumAttempts)
        #expect(world.cursor == userCursor)
    }

    @Test func stopsRetryingOnceTheDockArrivesLate() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)
        // The first gesture works, but macOS only reports the move during the retry wait.
        world.onSleep = { _ in
            if world.sleeps.last == .seconds(2) { world.dockLocation = .display(targetDisplay) }
        }

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.gestures == 1)
    }

    @Test func anUnknownDockLocationGetsOneBlindAttemptOnly() async {
        let world = FakeWorld(dock: .unknown)
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.gestures == 1)
        #expect(world.cursor == userCursor)
    }

    @Test func automaticIgnoresAHiddenDock() async {
        let world = FakeWorld(dock: .hidden)
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.moves.isEmpty)
    }

    @Test func manualAlwaysMakesOneAttempt() async {
        for location in [DockLocation.display(targetDisplay), .hidden, .unknown] {
            let world = FakeWorld(dock: location)
            let reanchorer = DockReanchorer(environment: world.environment)

            reanchorer.reanchor(mode: .manual) { target }
            await finish(reanchorer)

            #expect(world.gestures == 1, "manual re-anchor with the Dock \(location)")
            #expect(world.cursor == userCursor)
        }
    }

    @Test func nothingHappensWithoutATarget() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .manual) { nil }
        await finish(reanchorer)

        #expect(world.moves.isEmpty)
    }

    // The bug on main: a second request arriving mid-gesture recorded the Dock edge as the
    // "original" cursor position and left the cursor parked there.
    @Test func aSecondRequestMidGestureStillReturnsTheCursor() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)
        var restarted = false
        world.onSleep = { index in
            // Sleep 2 is between approach steps: the cursor is already away from the user's spot.
            if index == 2, !restarted {
                restarted = true
                #expect(world.cursor != userCursor)
                reanchorer.reanchor(mode: .automatic) { target }
            }
        }

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(restarted)
        #expect(world.cursor == userCursor)
    }

    // The other bug on main: the replaced task cleared the new task's handle, so cancel() could
    // no longer stop the cursor moving.
    @Test func cancelStopsARestartedRun() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)
        var step = 0
        world.onSleep = { index in
            if index == 2, step == 0 {
                step = 1
                reanchorer.reanchor(mode: .automatic) { target }
            } else if step == 1 {
                // First sleep of the restarted run: let the replaced task unwind, then cancel.
                step = 2
            } else if step == 2 {
                step = 3
                reanchorer.cancel()
            }
        }

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)
        let movesAtCancel = world.moves.count
        for _ in 0..<200 { await Task.yield() }

        #expect(step == 3)
        #expect(!reanchorer.isRunning)
        #expect(world.moves.count == movesAtCancel)
        #expect(world.cursor == userCursor)
    }

    @Test func cancelMidGestureReturnsTheCursor() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)
        world.onSleep = { index in
            if index == 3 { reanchorer.cancel() }
        }

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)
        for _ in 0..<200 { await Task.yield() }

        #expect(world.gestures == 1)
        #expect(world.cursor == userCursor)
    }

    @Test func waitsForTheMouseButtonToComeUp() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        world.dockFollowsCursorTo = targetDisplay
        world.buttonDown = true
        let reanchorer = DockReanchorer(environment: world.environment)
        world.onSleep = { index in
            if index <= 3 { #expect(world.moves.isEmpty, "cursor moved during a drag") }
            if index == 3 { world.buttonDown = false }
        }

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.gestures == 1)
        #expect(world.cursor == userCursor)
    }

    @Test func givesUpWhenTheMouseButtonStaysDown() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        world.buttonDown = true
        let reanchorer = DockReanchorer(environment: world.environment)

        reanchorer.reanchor(mode: .automatic) { target }
        await finish(reanchorer)

        #expect(world.moves.isEmpty)
    }

    @Test func rechecksTheTargetBeforeEveryAttempt() async {
        let world = FakeWorld(dock: .display(otherDisplay))
        let reanchorer = DockReanchorer(environment: world.environment)
        var targetStillValid = true
        world.onSleep = { _ in
            // Locking is switched off while the first gesture is being held.
            if world.gestures == 1 { targetStillValid = false }
        }

        reanchorer.reanchor(mode: .automatic) { targetStillValid ? target : nil }
        await finish(reanchorer)

        #expect(world.gestures == 1)
        #expect(world.cursor == userCursor)
    }
}
