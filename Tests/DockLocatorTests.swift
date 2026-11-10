import CoreGraphics
import Testing
@testable import DockPin

// The arrangement these fixes were developed against: a laptop panel with a larger monitor
// stacked above it and offset to the right. Window-server coordinates (top-left origin).
private let laptop: DockLocator.Display = (id: 1, bounds: CGRect(x: 0, y: 0, width: 2064, height: 1347))
private let monitor: DockLocator.Display = (id: 5, bounds: CGRect(x: 75, y: -1440, width: 2560, height: 1440))
private let displays = [laptop, monitor]

@Suite struct DockWindowMatchingTests {
    @Test func aDisplaySizedDockWindowNamesItsDisplay() {
        #expect(DockLocator.display(forDockWindows: [laptop.bounds], displays: displays) == laptop.id)
        #expect(DockLocator.display(forDockWindows: [monitor.bounds], displays: displays) == monitor.id)
    }

    @Test func aBarSizedDockWindowNamesItsDisplay() {
        let bar = CGRect(x: 400, y: 1282, width: 1200, height: 65)
        #expect(DockLocator.display(forDockWindows: [bar], displays: displays) == laptop.id)
    }

    @Test func noDockWindowMeansNoAnswer() {
        #expect(DockLocator.display(forDockWindows: [], displays: displays) == nil)
        #expect(DockLocator.display(forDockWindows: [.zero], displays: displays) == nil)
    }

    @Test func aWindowAcrossTwoDisplaysIsAmbiguous() {
        // Half on the monitor, half on the laptop below it.
        let straddling = CGRect(x: 400, y: -100, width: 800, height: 200)
        #expect(DockLocator.display(forDockWindows: [straddling], displays: displays) == nil)
    }

    @Test func aWindowOffEveryDisplayIsNoAnswer() {
        // A hidden Dock slid below the bottom of the lowest display.
        let offscreen = CGRect(x: 400, y: 1400, width: 1200, height: 65)
        #expect(DockLocator.display(forDockWindows: [offscreen], displays: displays) == nil)
    }

    @Test func dockWindowsOnDifferentDisplaysAreAmbiguous() {
        #expect(DockLocator.display(forDockWindows: [laptop.bounds, monitor.bounds], displays: displays) == nil)
    }

    @Test func severalDockWindowsOnOneDisplayStillAgree() {
        let bar = CGRect(x: 400, y: 1282, width: 1200, height: 65)
        #expect(DockLocator.display(forDockWindows: [laptop.bounds, bar], displays: displays) == laptop.id)
    }
}

@Suite struct DockInsetTests {
    // AppKit coordinates (bottom-left origin), same arrangement.
    private let laptopFrame = CGRect(x: 0, y: 0, width: 2064, height: 1347)
    private let monitorFrame = CGRect(x: 75, y: 1347, width: 2560, height: 1440)

    private func screens(dockOn id: CGDirectDisplayID?, edge: DockEdge) -> [DockLocator.Screen] {
        func visible(_ frame: CGRect, hasDock: Bool) -> CGRect {
            // Every screen loses a menu bar strip at the top; only the Dock's screen loses more.
            var visible = frame
            visible.size.height -= 30
            guard hasDock else { return visible }
            switch edge {
            case .bottom:
                visible.origin.y += 65
                visible.size.height -= 65
            case .left:
                visible.origin.x += 65
                visible.size.width -= 65
            case .right:
                visible.size.width -= 65
            }
            return visible
        }
        return [
            (id: 1, frame: laptopFrame, visibleFrame: visible(laptopFrame, hasDock: id == 1)),
            (id: 5, frame: monitorFrame, visibleFrame: visible(monitorFrame, hasDock: id == 5)),
        ]
    }

    @Test(arguments: [DockEdge.bottom, .left, .right])
    func theScreenWithSpaceReservedOnTheDockEdgeHasTheDock(edge: DockEdge) {
        #expect(DockLocator.displayWithDockInset(screens: screens(dockOn: 1, edge: edge), edge: edge) == 1)
        #expect(DockLocator.displayWithDockInset(screens: screens(dockOn: 5, edge: edge), edge: edge) == 5)
    }

    @Test func aHiddenDockReservesNothing() {
        #expect(DockLocator.displayWithDockInset(screens: screens(dockOn: nil, edge: .bottom), edge: .bottom) == nil)
    }

    @Test func theMenuBarIsNotMistakenForADock() {
        // Menu bar insets are at the top; a left-edge Dock check must not see them.
        #expect(DockLocator.displayWithDockInset(screens: screens(dockOn: nil, edge: .left), edge: .left) == nil)
    }
}

@Suite struct LockStatusTests {
    private func status(
        configured: Bool = true,
        enabled: Bool = true,
        trusted: Bool = true,
        separateSpaces: Bool = true,
        allowed: Bool = true,
        reachable: Bool = true,
        locking: Bool = true
    ) -> LockStatus {
        LockStatus.evaluate(
            isConfigured: configured,
            profileEnabled: enabled,
            isTrusted: trusted,
            hasSeparateSpaces: separateSpaces,
            hasAllowedDisplay: allowed,
            hasReachableAllowedDisplay: reachable,
            isLocking: locking
        )
    }

    @Test func reportsWhatIsActuallyHappening() {
        #expect(status() == .locking)
        #expect(status(configured: false) == .notConfigured)
        #expect(status(enabled: false) == .disabled)
        #expect(status(trusted: false) == .needsAccessibility)
        #expect(status(separateSpaces: false) == .separateSpacesOff)
        #expect(status(allowed: false, reachable: false) == .allowedDisplayMissing)
        #expect(status(reachable: false) == .edgeBlocked)
        #expect(status(locking: false) == .tapUnavailable)
    }

    // The bug on main: an enabled profile without Accessibility access showed as pinned.
    @Test func anEnabledProfileWithoutAccessIsNeverReportedAsLocking() {
        let withoutAccess = status(trusted: false, locking: false)
        #expect(withoutAccess == .needsAccessibility)
        #expect(withoutAccess.needsAttention)
        #expect(!withoutAccess.permitsLocking)
    }

    @Test func aDisabledProfileOutranksEveryOtherProblem() {
        #expect(status(enabled: false, trusted: false, separateSpaces: false, allowed: false, reachable: false) == .disabled)
    }

    @Test func theTapIsOnlyWantedWhenEveryConditionHolds() {
        #expect(status().permitsLocking)
        #expect(status(locking: false).permitsLocking)
        for blocked in [
            status(configured: false), status(enabled: false), status(trusted: false),
            status(separateSpaces: false), status(allowed: false, reachable: false), status(reachable: false),
        ] {
            #expect(!blocked.permitsLocking, "\(blocked) should not start the event tap")
        }
    }

    @Test func onlyStatesTheUserCanFixAskForAttention() {
        #expect(status(trusted: false).needsAttention)
        #expect(status(locking: false).needsAttention)
        // A laptop away from its monitors is normal, not a warning.
        #expect(!status(allowed: false, reachable: false).needsAttention)
        #expect(!status(reachable: false).needsAttention)
        #expect(!status().needsAttention)
    }

    @Test func everyNonObviousStateExplainsItself() {
        #expect(status().explanation(dockEdge: .bottom) == nil)
        #expect(status(enabled: false).explanation(dockEdge: .bottom) == nil)
        for state in [
            status(trusted: false), status(separateSpaces: false), status(allowed: false, reachable: false),
            status(reachable: false), status(locking: false),
        ] {
            #expect(state.explanation(dockEdge: .bottom) != nil, "\(state) has no explanation")
        }
    }
}
