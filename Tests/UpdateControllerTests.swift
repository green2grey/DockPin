import Foundation
import Testing
@testable import DockPin

/// Records what the update engine would be told, standing in for Sparkle.
@MainActor
private final class Updater {
    var choices: [UpdateChoice] = []
    var cancellations = 0
    var changes = 0

    func reply(_ choice: UpdateChoice) { choices.append(choice) }
    func cancel() { cancellations += 1 }
}

private let newVersion = UpdateInfo(version: "2.3")

@MainActor
private func controller(_ updater: Updater) -> UpdateController {
    let controller = UpdateController()
    controller.onChange = { updater.changes += 1 }
    return controller
}

@MainActor
@Suite struct UpdateFlowTests {
    @Test func aCheckThatFindsNothingSaysSoAndStaysOnShow() {
        let updater = Updater()
        let updates = controller(updater)

        updates.checkStarted(cancel: updater.cancel)
        #expect(updates.status == .checking)

        updates.noUpdateFound(message: "DockPin 2.2 is the newest version.")
        // Sparkle ends the round straight after; the result must not vanish with it.
        updates.sessionEnded()

        #expect(updates.status == .upToDate("DockPin 2.2 is the newest version."))
        #expect(!updates.status.awaitsDecision)
    }

    @Test func aCheckCanBeCancelled() {
        let updater = Updater()
        let updates = controller(updater)

        updates.checkStarted(cancel: updater.cancel)
        updates.cancel()
        updates.cancel()
        updates.sessionEnded()

        #expect(updater.cancellations == 1)
        #expect(updates.status == .idle)
    }

    @Test func installingRunsFromFoundToRelaunch() {
        let updater = Updater()
        let updates = controller(updater)

        updates.checkStarted(cancel: updater.cancel)
        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: true, reply: updater.reply)
        #expect(updates.status == .available(newVersion))
        #expect(updates.status.awaitsDecision)

        updates.install()
        #expect(updater.choices.count == 1)
        #expect(updates.status == .downloading(fraction: nil))

        updates.downloadStarted(cancel: updater.cancel)
        updates.downloadExpects(length: 2_000)
        updates.downloadReceived(length: 500)
        #expect(updates.status == .downloading(fraction: 0.25))
        updates.downloadReceived(length: 1_500)
        #expect(updates.status == .downloading(fraction: 1))

        updates.extractionStarted()
        updates.extractionProgressed(to: 0.5)
        #expect(updates.status == .preparing(fraction: 0.5))

        updates.readyToInstall(reply: updater.reply)
        #expect(updates.status == .readyToInstall)
        #expect(updates.status.awaitsDecision)

        updates.installAndRelaunch()
        #expect(updates.status == .installing)
        #expect(updater.choices.count == 2)
        if case .install = updater.choices[0], case .install = updater.choices[1] {} else {
            Issue.record("expected two install replies, got \(updater.choices)")
        }
    }

    @Test func eachDecisionIsSentExactlyOnce() {
        let updater = Updater()
        let updates = controller(updater)
        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: true, reply: updater.reply)

        updates.install()
        updates.install()
        updates.skip()
        updates.later()

        #expect(updater.choices.count == 1)
    }

    @Test func skippingAndPostponingAnswerTheUpdaterAndClearTheOffer() {
        for (act, expected) in [(UpdateController.skip, "skip"), (UpdateController.later, "later")] {
            let updater = Updater()
            let updates = controller(updater)
            updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: false, reply: updater.reply)

            act(updates)()

            #expect(updates.status == .idle)
            #expect(!updates.hasUnrequestedUpdate)
            #expect(updater.choices.map { "\($0)" } == [expected])
        }
    }

    @Test func aDownloadCanBeCancelled() {
        let updater = Updater()
        let updates = controller(updater)
        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: true, reply: updater.reply)
        updates.install()
        updates.downloadStarted(cancel: updater.cancel)

        updates.cancel()
        updates.sessionEnded()

        #expect(updater.cancellations == 1)
        #expect(updates.status == .idle)
    }

    @Test func progressIsReportedInWholePercents() {
        let updater = Updater()
        let updates = controller(updater)
        updates.downloadStarted(cancel: updater.cancel)
        updates.downloadExpects(length: 1_000_000)
        let before = updater.changes

        // A megabyte arriving a kilobyte at a time must not mean a thousand redraws.
        for _ in 0..<1_000 { updates.downloadReceived(length: 1_000) }

        #expect(updates.status == .downloading(fraction: 1))
        #expect(updater.changes - before <= 100)
    }

    @Test func anUnknownDownloadSizeShowsNoPercentage() {
        let updates = controller(Updater())
        updates.downloadStarted(cancel: {})
        updates.downloadReceived(length: 4_096)
        #expect(updates.status == .downloading(fraction: nil))
    }

    @Test func anUpdateFoundInTheBackgroundAsksForAttentionUntilAnswered() {
        let updater = Updater()
        let updates = controller(updater)

        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: false, reply: updater.reply)
        #expect(updates.hasUnrequestedUpdate)
        #expect(StatusItemVisibility.shouldShow(hiddenByUser: true, needsAttention: updates.hasUnrequestedUpdate))

        updates.install()
        #expect(!updates.hasUnrequestedUpdate)
    }

    @Test func anUpdateTheUserAskedAboutDoesNotNag() {
        let updates = controller(Updater())
        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: true, reply: { _ in })
        #expect(!updates.hasUnrequestedUpdate)
    }

    @Test func anUpdateAlreadyPreparedOnlyNeedsTheRelaunch() {
        let updater = Updater()
        let updates = controller(updater)

        updates.updateFound(newVersion, stage: .installing, userInitiated: false, reply: updater.reply)
        #expect(updates.status == .readyToInstall)

        updates.installAndRelaunch()
        #expect(updates.status == .installing)
        #expect(updater.choices.map { "\($0)" } == ["install"])
    }

    @Test func postponingAPreparedUpdateLeavesItForQuit() {
        let updater = Updater()
        let updates = controller(updater)
        updates.readyToInstall(reply: updater.reply)

        updates.later()

        #expect(updates.status == .idle)
        #expect(updater.choices.map { "\($0)" } == ["later"])
    }

    @Test func anInformationOnlyUpdateIsNeverInstalled() {
        let updater = Updater()
        let updates = controller(updater)
        let notice = UpdateInfo(version: "3.0", isInformationOnly: true, detailsURL: URL(string: "https://example.com/3"))
        updates.updateFound(notice, stage: .notDownloaded, userInitiated: true, reply: updater.reply)

        updates.install()

        #expect(updater.choices.map { "\($0)" } == ["later"])
        #expect(updates.status == .idle)
    }

    @Test func anErrorIsShownAndSurvivesTheEndOfTheRound() {
        let updater = Updater()
        let updates = controller(updater)
        updates.updateFound(newVersion, stage: .notDownloaded, userInitiated: true, reply: updater.reply)
        updates.install()

        updates.failed(message: "The update is improperly signed.")
        updates.sessionEnded()

        #expect(updates.status == .failed("The update is improperly signed."))
        // The failed round's reply is gone; a stale button press does nothing.
        updates.installAndRelaunch()
        updates.later()
        #expect(updater.choices.count == 1)
    }

    @Test func aNewCheckReplacesAnOldResult() {
        let updates = controller(Updater())
        updates.noUpdateFound(message: "Up to date.")
        updates.checkStarted(cancel: {})
        #expect(updates.status == .checking)
    }

    @Test func nothingIsAnnouncedWhenNothingChanged() {
        let updater = Updater()
        let updates = controller(updater)
        updates.sessionEnded()
        updates.sessionEnded()
        #expect(updater.changes == 0)
    }
}

@Suite struct OverrideKeyTests {
    private let f13 = CustomOverrideKey(keyCode: 105, label: "F13")
    private let monitorID = DisplayStableID(vendorID: 1, modelID: 2, serial: 3)

    private func profile(modifier: ModifierOption = .option, custom: CustomOverrideKey? = nil) -> DockProfile {
        DockProfile(name: "Work", isEnabled: true, overrideModifier: modifier,
                    allowedDisplays: [monitorID], customOverrideKey: custom)
    }

    @Test func theOverrideIsTheModifierUnlessAKeyWasRecorded() {
        #expect(profile().overrideTrigger == .modifier(.option))
        #expect(profile(modifier: .none).overrideTrigger == .none)
        #expect(profile(custom: f13).overrideTrigger == .key(f13))
    }

    // Versions before 2.2 can't read a modifier value they don't know, and lose every profile
    // when they hit one. A custom key therefore lives in its own field, with the old field left
    // holding a value those versions understand.
    @Test func aCustomKeyIsStoredSoOlderVersionsCanStillReadTheProfile() throws {
        let stored = try JSONEncoder().encode([profile(custom: f13)])
        let objects = try #require(try JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        let legacyValue = try #require(objects[0]["overrideModifier"] as? Int)

        #expect(ModifierOption(rawValue: legacyValue) == ModifierOption.none)
        #expect((objects[0]["customOverrideKey"] as? [String: Any])?["keyCode"] as? Int == 105)
    }

    @Test func aCustomKeySurvivesARoundTrip() throws {
        let original = profile(custom: f13)
        let decoded = try JSONDecoder().decode(DockProfile.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.overrideTrigger == .key(f13))
    }

    @Test func aProfileFromBeforeCustomKeysHasNone() throws {
        var objects = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode([profile(modifier: .command)])) as? [[String: Any]]
        )
        objects[0].removeValue(forKey: "customOverrideKey")
        let decoded = try JSONDecoder().decode([DockProfile].self, from: JSONSerialization.data(withJSONObject: objects))

        #expect(decoded.first?.customOverrideKey == nil)
        #expect(decoded.first?.overrideTrigger == .modifier(.command))
    }

    @Test func pickingAModifierAgainDropsTheCustomKey() {
        var edited = profile(custom: f13)
        edited.overrideModifier = .control
        edited.customOverrideKey = nil
        edited.sanitize()
        #expect(edited.overrideTrigger == .modifier(.control))
    }

    @Test func keysAreNamedForTheInterface() {
        #expect(KeyNames.label(keyCode: 105) == "F13")
        #expect(KeyNames.label(keyCode: 61) == "Right Option (⌥)")
        #expect(KeyNames.label(keyCode: 49) == "Space")
        #expect(KeyNames.label(keyCode: 0, characters: "a") == "A")
        #expect(KeyNames.label(keyCode: 41, characters: "ö") == "Ö")
        // A key that produced nothing printable still gets a usable name.
        #expect(KeyNames.label(keyCode: 200, characters: "\u{F704}") == "Key 200")
        #expect(KeyNames.label(keyCode: 200) == "Key 200")
    }

    @Test func onlyKeysThatTypeGetTheWarning() {
        #expect(!f13.doesSomethingWhenHeld)
        #expect(!CustomOverrideKey(keyCode: 61, label: "Right Option").doesSomethingWhenHeld)
        #expect(CustomOverrideKey(keyCode: 0, label: "A").doesSomethingWhenHeld)
        #expect(CustomOverrideKey(keyCode: 49, label: "Space").doesSomethingWhenHeld)
    }

    @Test func modifierKeysMapToTheFlagTheySet() {
        #expect(KeyNames.modifierFlag(for: 61) == .option)
        #expect(KeyNames.modifierFlag(for: 54) == .command)
        #expect(KeyNames.modifierFlag(for: 63) == .function)
        #expect(KeyNames.modifierFlag(for: 105) == nil)
    }

    @Test func theSettingsMenuShowsCustomWhenAKeyIsRecorded() {
        let snapshot = DisplaySnapshot(displays: [])
        func choice(_ profile: DockProfile) -> SettingsState {
            SettingsState(SettingsState.Inputs(
                profiles: [profile], activeProfileID: profile.id, snapshot: snapshot,
                reachability: [:], dockEdge: .bottom, lockStatus: .disabled
            ))
        }
        #expect(choice(profile()).overrideChoice == .modifier(.option))
        #expect(choice(profile(custom: f13)).overrideChoice == .custom)
        #expect(choice(profile(custom: f13)).customOverrideKey == f13)
    }
}
