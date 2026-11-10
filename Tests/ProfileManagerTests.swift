import CoreGraphics
import Foundation
import Testing
@testable import DockPin

/// A throwaway defaults domain, removed when the test ends.
private final class ScratchDefaults {
    let name = "DockPinTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

private let profilesKey = "v2.profiles"
private let backupKey = "v2.profilesUnreadableBackup"

private let builtIn = DisplayStableID(vendorID: 1552, modelID: 41000, serial: 0)
private let officeMonitor = DisplayStableID(vendorID: 1, modelID: 10, serial: 111)
private let secondOfficeMonitor = DisplayStableID(vendorID: 1, modelID: 10, serial: 222)
private let homeMonitor = DisplayStableID(vendorID: 2, modelID: 20, serial: 333)

private func descriptor(_ id: CGDirectDisplayID, _ stableID: DisplayStableID, builtIn: Bool = false) -> DisplayDescriptor {
    DisplayDescriptor(
        displayID: id,
        stableID: stableID,
        localizedName: "Display \(id)",
        frame: CGRect(x: CGFloat(id) * 2000, y: 0, width: 1920, height: 1080),
        isBuiltIn: builtIn,
        isMirroredSecondary: false
    )
}

private func snapshot(_ stableIDs: DisplayStableID...) -> DisplaySnapshot {
    DisplaySnapshot(displays: stableIDs.enumerated().map { index, stableID in
        descriptor(CGDirectDisplayID(index + 1), stableID, builtIn: stableID == builtIn)
    })
}

private func profile(_ name: String, allowed: DisplayStableID, trigger: [DisplayStableID: Int]? = nil) -> DockProfile {
    DockProfile(
        name: name,
        isEnabled: true,
        overrideModifier: .option,
        allowedDisplays: [allowed],
        triggerRequirements: trigger
    )
}

/// The stored JSON for some profiles, with a chance to damage individual entries.
private func storedJSON(_ profiles: [DockProfile], mutate: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
    let encoded = try JSONEncoder().encode(profiles)
    var objects = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    mutate(&objects)
    return try JSONSerialization.data(withJSONObject: objects)
}

@Suite struct ProfileLoadingTests {
    @Test func profilesSurviveARoundTrip() {
        let scratch = ScratchDefaults()
        let original = profile("Office", allowed: officeMonitor, trigger: [officeMonitor: 1])
        ProfileManager(defaults: scratch.defaults).addProfile(original)

        let reloaded = ProfileManager(defaults: scratch.defaults)
        #expect(reloaded.profiles == [original])
        #expect(reloaded.activeProfileID == original.id)
        #expect(reloaded.unacknowledgedLoadIssue == nil)
    }

    @Test func nothingIsWrittenWhenNothingIsStored() {
        let scratch = ScratchDefaults()
        let manager = ProfileManager(defaults: scratch.defaults)

        #expect(manager.profiles.isEmpty)
        #expect(scratch.defaults.object(forKey: profilesKey) == nil)
        #expect(manager.unacknowledgedLoadIssue == nil)
    }

    @Test func unreadableDataIsKeptNotOverwritten() {
        let scratch = ScratchDefaults()
        let garbage = Data("definitely not profiles".utf8)
        scratch.defaults.set(garbage, forKey: profilesKey)

        let manager = ProfileManager(defaults: scratch.defaults)

        #expect(manager.profiles.isEmpty)
        #expect(manager.unacknowledgedLoadIssue == .unreadable)
        #expect(scratch.defaults.data(forKey: profilesKey) == garbage)
        #expect(scratch.defaults.data(forKey: backupKey) == garbage)
    }

    @Test func oneDamagedProfileDoesNotCostTheOthers() throws {
        let scratch = ScratchDefaults()
        let good = profile("Office", allowed: officeMonitor)
        let stored = try storedJSON([good, profile("Home", allowed: homeMonitor)]) { objects in
            objects[1].removeValue(forKey: "id")
        }
        scratch.defaults.set(stored, forKey: profilesKey)

        let manager = ProfileManager(defaults: scratch.defaults)

        #expect(manager.profiles == [good])
        #expect(manager.unacknowledgedLoadIssue == .skippedProfiles(1))
        #expect(scratch.defaults.data(forKey: profilesKey) == stored)
        #expect(scratch.defaults.data(forKey: backupKey) == stored)
    }

    @Test func backupSurvivesALaterSave() throws {
        let scratch = ScratchDefaults()
        let good = profile("Office", allowed: officeMonitor)
        let stored = try storedJSON([good, profile("Home", allowed: homeMonitor)]) { objects in
            objects[1]["allowedDisplays"] = "oops"
        }
        scratch.defaults.set(stored, forKey: profilesKey)

        let manager = ProfileManager(defaults: scratch.defaults)
        manager.updateProfile(id: good.id) { $0.isEnabled = false }

        #expect(scratch.defaults.data(forKey: profilesKey) != stored)
        #expect(scratch.defaults.data(forKey: backupKey) == stored)
    }

    @Test func aLoadIssueIsReportedOncePerStoredData() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(Data("garbage".utf8), forKey: profilesKey)

        let first = ProfileManager(defaults: scratch.defaults)
        #expect(first.unacknowledgedLoadIssue == .unreadable)
        first.acknowledgeLoadIssue()
        #expect(first.unacknowledgedLoadIssue == nil)

        #expect(ProfileManager(defaults: scratch.defaults).unacknowledgedLoadIssue == nil)

        scratch.defaults.set(Data("different garbage".utf8), forKey: profilesKey)
        #expect(ProfileManager(defaults: scratch.defaults).unacknowledgedLoadIssue == .unreadable)
    }

    @Test func settingsFromAnotherVersionFallBackToDefaults() throws {
        let scratch = ScratchDefaults()
        let original = profile("Office", allowed: officeMonitor)
        let stored = try storedJSON([original]) { objects in
            objects[0]["overrideModifier"] = 99
            objects[0]["mirroringPolicy"] = "somethingNew"
            objects[0]["addedInAFutureVersion"] = true
        }
        scratch.defaults.set(stored, forKey: profilesKey)

        let manager = ProfileManager(defaults: scratch.defaults)

        #expect(manager.unacknowledgedLoadIssue == nil)
        let loaded = try #require(manager.profiles.first)
        #expect(loaded.id == original.id)
        #expect(loaded.allowedDisplays == [officeMonitor])
        #expect(loaded.overrideModifier == .option)
        #expect(loaded.mirroringPolicy == .ignoreMirroredSecondaries)
    }
}

@Suite struct AutoSwitchTests {
    private func manager(_ scratch: ScratchDefaults, profiles: [DockProfile]) -> ProfileManager {
        let manager = ProfileManager(defaults: scratch.defaults)
        for profile in profiles {
            manager.addProfile(profile, makeActive: false)
        }
        manager.setupCompleted = true
        return manager
    }

    @Test func triggerIsTheExternalDisplays() {
        let trigger = ProfileManager.triggerRequirements(
            for: snapshot(builtIn, officeMonitor, secondOfficeMonitor),
            mirroringPolicy: .ignoreMirroredSecondaries
        )
        #expect(trigger == [officeMonitor: 1, secondOfficeMonitor: 1])
    }

    @Test func noTriggerWithoutAnExternalDisplay() {
        let trigger = ProfileManager.triggerRequirements(
            for: snapshot(builtIn),
            mirroringPolicy: .ignoreMirroredSecondaries
        )
        #expect(trigger == nil)
    }

    @Test func theProfileForTheConnectedDisplaysWins() {
        let scratch = ScratchDefaults()
        let office = profile("Office", allowed: officeMonitor, trigger: [officeMonitor: 1, secondOfficeMonitor: 1])
        let home = profile("Home", allowed: homeMonitor, trigger: [homeMonitor: 1])
        let manager = manager(scratch, profiles: [office, home])

        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn, officeMonitor, secondOfficeMonitor))?.id == office.id)
        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn, homeMonitor))?.id == home.id)
    }

    @Test func aProfileMadeWithTheLidOpenStillMatchesInClamshell() {
        let scratch = ScratchDefaults()
        let lidOpen = snapshot(builtIn, officeMonitor, secondOfficeMonitor)
        let office = profile(
            "Office",
            allowed: officeMonitor,
            trigger: ProfileManager.triggerRequirements(for: lidOpen, mirroringPolicy: .ignoreMirroredSecondaries)
        )
        let manager = manager(scratch, profiles: [office])

        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(officeMonitor, secondOfficeMonitor))?.id == office.id)
    }

    @Test func nothingMatchesAwayFromEveryKnownSetup() {
        let scratch = ScratchDefaults()
        let manager = manager(scratch, profiles: [
            profile("Office", allowed: officeMonitor, trigger: [officeMonitor: 1]),
            profile("Home", allowed: homeMonitor, trigger: [homeMonitor: 1]),
        ])

        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn)) == nil)
    }

    @Test func theMoreSpecificProfileWins() {
        let scratch = ScratchDefaults()
        let one = profile("One monitor", allowed: officeMonitor, trigger: [officeMonitor: 1])
        let two = profile("Two monitors", allowed: officeMonitor, trigger: [officeMonitor: 1, secondOfficeMonitor: 1])
        let manager = manager(scratch, profiles: [one, two])

        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn, officeMonitor, secondOfficeMonitor))?.id == two.id)
        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn, officeMonitor))?.id == one.id)
    }

    @Test func aTieSwitchesNothing() {
        let scratch = ScratchDefaults()
        let manager = manager(scratch, profiles: [
            profile("Dock left", allowed: officeMonitor, trigger: [officeMonitor: 1]),
            profile("Dock right", allowed: secondOfficeMonitor, trigger: [officeMonitor: 1]),
        ])

        #expect(manager.bestAutoSwitchMatch(snapshot: snapshot(builtIn, officeMonitor)) == nil)
    }

    @Test func manualHoldAndTheSwitchItselfAreRespected() {
        let scratch = ScratchDefaults()
        let office = profile("Office", allowed: officeMonitor, trigger: [officeMonitor: 1])
        let manager = manager(scratch, profiles: [office])
        let atOffice = snapshot(builtIn, officeMonitor)

        manager.manualHoldEnabled = true
        #expect(manager.bestAutoSwitchMatch(snapshot: atOffice) == nil)

        manager.manualHoldEnabled = false
        manager.autoSwitchEnabled = false
        #expect(manager.bestAutoSwitchMatch(snapshot: atOffice) == nil)
    }

    @Test func savingAProfileRecordsTheCurrentDisplays() throws {
        let scratch = ScratchDefaults()
        let manager = manager(scratch, profiles: [])
        manager.addProfile(profile("Office", allowed: officeMonitor), makeActive: true)

        let saved = try #require(manager.saveCurrentAsProfile(name: "Home", snapshot: snapshot(builtIn, homeMonitor)))

        #expect(saved.triggerRequirements == [homeMonitor: 1])
    }

    @Test func aProfileFromBeforeTriggersLearnsWhenPickedByHand() throws {
        let scratch = ScratchDefaults()
        let legacy = profile("Office", allowed: officeMonitor)
        let manager = manager(scratch, profiles: [legacy])
        let atOffice = snapshot(builtIn, officeMonitor)

        #expect(manager.bestAutoSwitchMatch(snapshot: atOffice) == nil)

        manager.learnTriggerIfMissing(id: legacy.id, snapshot: atOffice)
        #expect(manager.profiles.first?.triggerRequirements == [officeMonitor: 1])
        #expect(manager.bestAutoSwitchMatch(snapshot: atOffice)?.id == legacy.id)

        // Once a profile has a trigger, picking it somewhere else doesn't rebind it.
        manager.learnTriggerIfMissing(id: legacy.id, snapshot: snapshot(builtIn, homeMonitor))
        #expect(manager.profiles.first?.triggerRequirements == [officeMonitor: 1])
    }
}
