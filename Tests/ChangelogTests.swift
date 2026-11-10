import Foundation
import Testing
@testable import DockPin

/// The repository root, found from this file's own location.
private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@Suite struct ChangelogParsingTests {
    private let sample = """
    # Changelog

    Some introduction that is not part of any release.
    - a stray bullet before any version is ignored too

    ## 2.2

    ### New
    - A Settings window.
    - Hide the menu bar icon.

    ### Fixed
    * Re-anchor works again.

    ## 2.1 - 2026-03-13
    - Left and right Dock positions.

    ## 2.0

    Nothing listed for this one.
    """

    @Test func readsVersionsSectionsAndItems() {
        let entries = Changelog.parse(sample)

        #expect(entries.map(\.version) == ["2.2", "2.1"])
        #expect(entries[0].sections.map(\.title) == ["New", "Fixed"])
        #expect(entries[0].sections[0].items == ["A Settings window.", "Hide the menu bar icon."])
        #expect(entries[0].sections[1].items == ["Re-anchor works again."])
        #expect(entries[0].items.count == 3)
    }

    @Test func itemsDirectlyUnderAVersionNeedNoSection() {
        let entry = Changelog.parse(sample)[1]
        #expect(entry.version == "2.1")
        #expect(entry.sections == [ChangelogEntry.Section(title: nil, items: ["Left and right Dock positions."])])
    }

    @Test func aVersionWithNothingListedIsLeftOut() {
        #expect(!Changelog.parse(sample).contains { $0.version == "2.0" })
        #expect(Changelog.parse("").isEmpty)
        #expect(Changelog.parse("# Changelog\n\njust words").isEmpty)
    }

    // A release without an entry would offer people an update with nothing to read, and the
    // build script refuses to make one. This catches it earlier.
    @Test func theVersionBeingBuiltHasAnEntry() throws {
        let plist = try #require(NSDictionary(contentsOf: repositoryRoot.appendingPathComponent("Info.plist")))
        let version = try #require(plist["CFBundleShortVersionString"] as? String)
        let text = try String(contentsOf: repositoryRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)

        let entries = Changelog.parse(text)
        let entry = try #require(entries.first { $0.version == version }, "CHANGELOG.md has no entry for \(version)")
        #expect(entries.first?.version == version, "the newest entry should be the version being built")
        #expect(entry.items.count >= 3)
        // The build script turns each item into one line of the feed; keep them plain.
        #expect(entry.items.allSatisfy { !$0.contains("**") && !$0.contains("`") && !$0.contains("](") })
    }

    @MainActor
    @Test func theWhatsNewWindowListsEverythingNewestFirst() {
        let text = Changelog.attributedString(for: Changelog.parse(sample)).string
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.first == "Version 2.2")
        #expect(lines.contains("New"))
        #expect(lines.contains("•\tHide the menu bar icon."))
        #expect(text.range(of: "Version 2.2")!.lowerBound < text.range(of: "Version 2.1")!.lowerBound)
    }
}

@Suite struct ReleaseNotesTests {
    // The shape build.sh writes into the update feed.
    private let feedHTML = """

    <style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif}li{margin:3px 0}</style>
    <h3>New</h3>
    <ul>
    <li>A Settings window. The menu is now short (pin, re-anchor, switch profile).</li>
    <li>Turn off "Show in menu bar" under Settings → General.</li>
    </ul>
    <h3>Fixed</h3>
    <ul>
    <li>Copy &amp; paste now work; values &lt; 1 are fine.</li>
    </ul>

    """

    @Test func readsTheListItemsOutOfTheFeed() {
        #expect(ReleaseNotes.items(fromHTML: feedHTML) == [
            "A Settings window. The menu is now short (pin, re-anchor, switch profile).",
            "Turn off \"Show in menu bar\" under Settings → General.",
            "Copy & paste now work; values < 1 are fine.",
        ])
    }

    @Test func stylesAndMarkupNeverLeakIntoTheText() {
        let items = ReleaseNotes.items(fromHTML: feedHTML)
        #expect(items.allSatisfy { !$0.contains("<") || $0.contains("< 1") })
        #expect(!items.joined().contains("color-scheme"))

        let nested = ReleaseNotes.items(fromHTML: "<ul><li class=\"x\">A <b>bold</b>\n  claim</li></ul>")
        #expect(nested == ["A bold claim"])
    }

    @Test func notesWithoutAListFallBackToTheirLines() {
        let html = "<p>First thing.</p><p>Second thing.</p><script>alert(1)</script>"
        #expect(ReleaseNotes.items(fromHTML: html) == ["First thing.", "Second thing."])
        #expect(ReleaseNotes.items(fromHTML: "").isEmpty)
    }

    @Test func plainTextNotesAreOneItemPerLine() {
        let text = "# 2.3\n- First thing.\n\n• Second thing.\nThird thing."
        #expect(ReleaseNotes.items(fromPlainText: text) == ["First thing.", "Second thing.", "Third thing."])
    }
}

@MainActor
@Suite struct ReleaseNotesInTheUpdateFlowTests {
    @Test func notesThatArriveLaterAreAddedToTheOffer() {
        let updates = UpdateController()
        updates.updateFound(UpdateInfo(version: "2.3"), stage: .notDownloaded, userInitiated: true, reply: { _ in })

        updates.releaseNotesArrived(["A change."])

        #expect(updates.status == .available(UpdateInfo(version: "2.3", notes: ["A change."])))
    }

    @Test func notesFromTheFeedItselfAreNotReplaced() {
        let updates = UpdateController()
        let offered = UpdateInfo(version: "2.3", notes: ["From the feed."])
        updates.updateFound(offered, stage: .notDownloaded, userInitiated: true, reply: { _ in })

        updates.releaseNotesArrived(["From a link."])

        #expect(updates.status == .available(offered))
    }

    @Test func notesAreIgnoredWhenNoUpdateIsOnOffer() {
        let updates = UpdateController()
        updates.releaseNotesArrived(["A change."])
        #expect(updates.status == .idle)
    }

    @Test func installingStillWorksAfterNotesArrive() {
        let updates = UpdateController()
        var choices: [UpdateChoice] = []
        updates.updateFound(UpdateInfo(version: "2.3"), stage: .notDownloaded, userInitiated: true) { choices.append($0) }
        updates.releaseNotesArrived(["A change."])

        updates.install()

        #expect(choices.count == 1)
        #expect(updates.status == .downloading(fraction: nil))
    }
}

@Suite struct UpgradeNoticeTests {
    @Test func aBrandNewInstallGetsNoWhatsNew() {
        #expect(!UpgradeNotice.shouldShow(previousVersion: nil, currentVersion: "2.2", hadEarlierInstall: false))
    }

    // 2.1 and earlier never recorded which version ran, so an update from one of them is
    // recognised by what it left behind instead.
    @Test func updatingFromAVersionThatKeptNoRecordShowsIt() {
        #expect(UpgradeNotice.shouldShow(previousVersion: nil, currentVersion: "2.2", hadEarlierInstall: true))
    }

    @Test func aNewVersionShowsItOnceAndTheSameVersionNeverAgain() {
        #expect(UpgradeNotice.shouldShow(previousVersion: "2.2", currentVersion: "2.3", hadEarlierInstall: true))
        #expect(!UpgradeNotice.shouldShow(previousVersion: "2.3", currentVersion: "2.3", hadEarlierInstall: true))
    }

    @Test func theVersionThatLastRanIsRemembered() {
        let name = "DockPinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(ProfileManager(defaults: defaults).lastRunVersion == nil)
        ProfileManager(defaults: defaults).lastRunVersion = "2.2"
        #expect(ProfileManager(defaults: defaults).lastRunVersion == "2.2")
    }
}
