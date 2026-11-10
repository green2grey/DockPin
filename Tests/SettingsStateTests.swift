import CoreGraphics
import Foundation
import Testing
@testable import DockPin

private let laptopID = DisplayStableID(vendorID: 1552, modelID: 41065, serial: 0)
private let monitorID = DisplayStableID(vendorID: 1715, modelID: 13025, serial: 98307)
private let homeMonitorID = DisplayStableID(vendorID: 4268, modelID: 53443, serial: 77)

// A laptop with a larger monitor above it that hangs over on both sides (AppKit coordinates).
private let laptop = DisplayDescriptor(
    displayID: 1, stableID: laptopID, localizedName: "Built-in Display",
    frame: CGRect(x: 0, y: 0, width: 2064, height: 1347), isBuiltIn: true, isMirroredSecondary: false
)
private let monitor = DisplayDescriptor(
    displayID: 5, stableID: monitorID, localizedName: "ASUS PG32UQ",
    frame: CGRect(x: -226, y: 1347, width: 2560, height: 1440), isBuiltIn: false, isMirroredSecondary: false
)
// The same monitor sitting exactly on top of a laptop of the same width: its bottom edge is covered.
private let coveredMonitor = DisplayDescriptor(
    displayID: 5, stableID: monitorID, localizedName: "ASUS PG32UQ",
    frame: CGRect(x: 0, y: 1347, width: 2064, height: 1440), isBuiltIn: false, isMirroredSecondary: false
)

private let names = [
    laptopID.storageKey: "Built-in Display",
    monitorID.storageKey: "ASUS PG32UQ",
    homeMonitorID.storageKey: "LG UltraFine",
]

private func profile(
    _ name: String = "Work",
    enabled: Bool = true,
    allowed: Set<DisplayStableID> = [monitorID],
    trigger: [DisplayStableID: Int]? = [monitorID: 1]
) -> DockProfile {
    DockProfile(name: name, isEnabled: enabled, overrideModifier: .option,
                allowedDisplays: allowed, triggerRequirements: trigger)
}

private func state(
    _ profiles: [DockProfile],
    displays: [DisplayDescriptor] = [laptop, monitor],
    status: LockStatus = .locking,
    configure: (inout SettingsState.Inputs) -> Void = { _ in }
) -> SettingsState {
    let snapshot = DisplaySnapshot(displays: displays)
    var inputs = SettingsState.Inputs(
        profiles: profiles,
        activeProfileID: profiles.first?.id,
        snapshot: snapshot,
        reachability: DisplayLayoutAnalyzer.reachabilityMap(snapshot: snapshot, edge: .bottom),
        dockEdge: .bottom,
        lockStatus: status,
        dockDisplay: 5,
        displayNames: names
    )
    configure(&inputs)
    return SettingsState(inputs)
}

@Suite struct DisplayRowTests {
    @Test func connectedDisplaysShowWhetherTheyAreAllowedAndWhereTheDockIs() throws {
        let rows = state([profile()]).displays

        #expect(rows.map(\.name) == ["Built-in Display", "ASUS PG32UQ"])
        let laptopRow = try #require(rows.first)
        let monitorRow = try #require(rows.last)
        #expect(!laptopRow.isAllowed)
        #expect(laptopRow.isBuiltIn)
        #expect(laptopRow.caption == nil)
        #expect(monitorRow.isAllowed)
        #expect(monitorRow.hasDock)
        #expect(monitorRow.caption == "The Dock is here now")
    }

    @Test func theLastAllowedDisplayCannotBeSwitchedOff() throws {
        let only = try #require(state([profile()]).displays.last)
        #expect(only.isAllowed)
        #expect(!only.canDisallow)

        let both = state([profile(allowed: [monitorID, laptopID])]).displays
        #expect(both.allSatisfy { $0.isAllowed && $0.canDisallow })
    }

    @Test func aDisplayThatCannotHostTheDockSaysWhy() throws {
        let rows = state([profile()], displays: [laptop, coveredMonitor], status: .edgeBlocked).displays
        let monitorRow = try #require(rows.last)

        #expect(monitorRow.blockedReason?.contains("another display is directly below it") == true)
        #expect(monitorRow.caption == monitorRow.blockedReason)
    }

    @Test func anAllowedDisplayThatIsUnpluggedIsStillListedByName() throws {
        let rows = state([profile(allowed: [monitorID, homeMonitorID])]).displays

        #expect(rows.count == 3)
        let missing = try #require(rows.last)
        #expect(missing.name == "LG UltraFine")
        #expect(!missing.isConnected)
        #expect(missing.isAllowed)
        #expect(missing.canDisallow)
        #expect(missing.caption == "Not connected")
    }

    @Test func anUnpluggedDisplayNobodyHasNamedIsStillListed() throws {
        let stranger = DisplayStableID(vendorID: 9, modelID: 9, serial: 9)
        let rows = state([profile(allowed: [monitorID, stranger])]).displays
        #expect(rows.last?.name == "Unknown display")
    }

    @Test func aStoredIDWithoutASerialCoversEveryDisplayOfThatModel() {
        // Two identical monitors that report no serial are one entry in the profile.
        let model = DisplayStableID(vendorID: 7, modelID: 7, serial: 0)
        let left = DisplayDescriptor(displayID: 2, stableID: model, localizedName: "Twin",
                                     frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                     isBuiltIn: false, isMirroredSecondary: false)
        let right = DisplayDescriptor(displayID: 3, stableID: model, localizedName: "Twin",
                                      frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                      isBuiltIn: false, isMirroredSecondary: false)
        let rows = state([profile(allowed: [model], trigger: nil)], displays: [left, right]).displays

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.isAllowed && !$0.canDisallow })
        #expect(Set(rows.map(\.id)).count == 2)
    }
}

@Suite struct SettingsSummaryTests {
    @Test func saysWhichDisplayTheDockIsPinnedTo() {
        let pinned = state([profile()])
        #expect(pinned.statusDetail == "Keeping the Dock on ASUS PG32UQ.")
        #expect(pinned.menuStatus == "Pinned to ASUS PG32UQ")
        #expect(pinned.pinningEnabled)

        let both = state([profile(allowed: [monitorID, laptopID])])
        #expect(both.menuStatus == "Pinned to Built-in Display and ASUS PG32UQ")
    }

    @Test func everyStatusHasWordsForTheMenuAndTheWindow() {
        let all: [LockStatus] = [.notConfigured, .disabled, .locking, .needsAccessibility, .separateSpacesOff,
                                 .allowedDisplayMissing, .edgeBlocked, .tapUnavailable]
        for status in all {
            let result = state([profile()], status: status)
            #expect(!result.statusDetail.isEmpty, "\(status) has no detail")
            #expect(!result.menuStatus.isEmpty, "\(status) has no menu text")
        }
    }

    @Test func pinningCanBeTurnedOnOnlyWhenItCouldWork() {
        let ready = state([profile(enabled: false)], status: .disabled)
        #expect(ready.enableBlockedReason == nil)

        let oneDisplay = state([profile(enabled: false, allowed: [laptopID])], displays: [laptop], status: .disabled)
        #expect(oneDisplay.enableBlockedReason == "Connect a second display to use DockPin.")

        let nothingConnected = state([profile(enabled: false, allowed: [homeMonitorID])], status: .disabled)
        #expect(nothingConnected.enableBlockedReason == "Allow at least one connected display first.")

        let covered = state([profile(enabled: false)], displays: [laptop, coveredMonitor], status: .disabled)
        #expect(covered.enableBlockedReason?.contains("free bottom edge") == true)

        let spacesOff = state([profile(enabled: false)], status: .disabled) { $0.hasSeparateSpaces = false }
        #expect(spacesOff.enableBlockedReason?.contains("separate Spaces") == true)
    }

    @Test func pinningCanAlwaysBeTurnedOff() {
        // Whatever stops it from working, an enabled profile must stay switch-off-able.
        let stuck = state([profile()], displays: [laptop], status: .allowedDisplayMissing) { $0.hasSeparateSpaces = false }
        #expect(stuck.pinningEnabled)
        #expect(stuck.enableBlockedReason == nil)
    }

    @Test func withoutAProfileThereIsNothingToPin() {
        let empty = state([], status: .notConfigured)
        #expect(!empty.hasProfile)
        #expect(empty.displays.allSatisfy { !$0.isAllowed })
        #expect(empty.enableBlockedReason != nil)
        #expect(empty.menuStatus == "DockPin isn’t set up")
    }
}

@Suite struct ProfileRowTests {
    @Test func profilesSayWhichDisplaysTheyBelongTo() {
        let work = profile("Work")
        let home = profile("Home", allowed: [homeMonitorID], trigger: [homeMonitorID: 1])
        let legacy = profile("Old", trigger: nil)
        let result = state([work, home, legacy])

        #expect(result.profiles.map(\.name) == ["Work", "Home", "Old"])
        #expect(result.profiles.map(\.isActive) == [true, false, false])
        #expect(result.profiles.map(\.triggerSummary) == [
            "Linked to ASUS PG32UQ", "Linked to LG UltraFine", "Not linked to any displays",
        ])
        #expect(result.activeProfileName == "Work")
    }

    @Test func autoSwitchingIsOnlyPausedWhileItIsOn() {
        #expect(state([profile()]) { $0.manualHoldEnabled = true }.autoSwitchPaused)
        #expect(!state([profile()]) { $0.manualHoldEnabled = true; $0.autoSwitchEnabled = false }.autoSwitchPaused)
        #expect(!state([profile()]).autoSwitchPaused)
    }
}

@Suite struct MenuBarIconTests {
    @Test func theIconShowsUnlessTheUserHidIt() {
        #expect(StatusItemVisibility.shouldShow(hiddenByUser: false, needsAttention: false))
        #expect(!StatusItemVisibility.shouldShow(hiddenByUser: true, needsAttention: false))
    }

    // With the icon hidden there would be no sign that DockPin had stopped working.
    @Test func aHiddenIconComesBackWhenDockPinNeedsAttention() {
        #expect(StatusItemVisibility.shouldShow(hiddenByUser: true, needsAttention: true))
        #expect(LockStatus.needsAccessibility.needsAttention)
        #expect(!LockStatus.locking.needsAttention)
        #expect(!LockStatus.allowedDisplayMissing.needsAttention)
    }
}

@Suite struct ProfileManagementTests {
    @Test func renamingKeepsEverythingElse() throws {
        let scratch = InMemoryDefaults()
        let manager = ProfileManager(defaults: scratch)
        let original = profile("Work")
        manager.addProfile(original)

        manager.renameProfile(id: original.id, to: "  Office  ")
        #expect(manager.profiles.first?.name == "Office")
        #expect(manager.profiles.first?.allowedDisplays == original.allowedDisplays)

        manager.renameProfile(id: original.id, to: "   ")
        #expect(manager.profiles.first?.name == "Office")
        #expect(ProfileManager(defaults: scratch).profiles.first?.name == "Office")
    }

    @Test func newProfilesGetANameThatIsNotTaken() {
        let scratch = InMemoryDefaults()
        let manager = ProfileManager(defaults: scratch)
        #expect(manager.unusedProfileName() == "Profile")

        manager.addProfile(profile("Profile"))
        #expect(manager.unusedProfileName() == "Profile 2")
        manager.addProfile(profile("profile 2"))
        #expect(manager.unusedProfileName() == "Profile 3")
        #expect(manager.unusedProfileName(base: "Default") == "Default")
    }

    @Test func relinkingReplacesTheTrigger() {
        let scratch = InMemoryDefaults()
        let manager = ProfileManager(defaults: scratch)
        let work = profile("Work")
        manager.addProfile(work)

        let atHome = DisplaySnapshot(displays: [
            laptop,
            DisplayDescriptor(displayID: 7, stableID: homeMonitorID, localizedName: "LG UltraFine",
                              frame: CGRect(x: 2064, y: 0, width: 2560, height: 1440),
                              isBuiltIn: false, isMirroredSecondary: false),
        ])
        manager.relinkTrigger(id: work.id, snapshot: atHome)
        #expect(manager.profiles.first?.triggerRequirements == [homeMonitorID: 1])

        manager.relinkTrigger(id: work.id, snapshot: DisplaySnapshot(displays: [laptop]))
        #expect(manager.profiles.first?.triggerRequirements == nil)
    }

    @Test func displayNamesAreRememberedAfterUnplugging() {
        let scratch = InMemoryDefaults()
        let manager = ProfileManager(defaults: scratch)
        manager.rememberDisplayNames(from: DisplaySnapshot(displays: [laptop, monitor]))
        manager.rememberDisplayNames(from: DisplaySnapshot(displays: [laptop]))

        #expect(manager.displayNames[monitorID.storageKey] == "ASUS PG32UQ")
        #expect(ProfileManager(defaults: scratch).displayNames[monitorID.storageKey] == "ASUS PG32UQ")
    }

    @Test func theMenuBarIconPreferencePersists() {
        let scratch = InMemoryDefaults()
        #expect(!ProfileManager(defaults: scratch).hidesMenuBarIcon)
        ProfileManager(defaults: scratch).hidesMenuBarIcon = true
        #expect(ProfileManager(defaults: scratch).hidesMenuBarIcon)
    }

    @Test func aStoredIDCoversTheRightDisplays() {
        let exact = DisplayStableID(vendorID: 1, modelID: 2, serial: 3)
        let sameModelOtherSerial = DisplayStableID(vendorID: 1, modelID: 2, serial: 4)
        let noSerial = DisplayStableID(vendorID: 1, modelID: 2, serial: 0)

        #expect(exact.covers(exact))
        #expect(!exact.covers(sameModelOtherSerial))
        #expect(noSerial.covers(exact))
        #expect(noSerial.covers(sameModelOtherSerial))
        #expect(!exact.covers(noSerial))
    }
}
