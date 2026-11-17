import Foundation
import Testing
@testable import DockPin

@Suite struct LocalizationTests {

    private func temporaryStringsFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Localizable.strings")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsAStringsFile() throws {
        let url = try temporaryStringsFile("""
        "Pin the Dock" = "固定程序坞";
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let table = Localization.loadTable(url: url)
        #expect(table["Pin the Dock"] == "固定程序坞")
    }

    @Test func missingTableFallsBackToNoTranslations() {
        #expect(Localization.loadTable(url: nil).isEmpty)
        #expect(Localization.loadTable(url: URL(fileURLWithPath: "/nonexistent/Localizable.strings")).isEmpty)
    }

    @Test func untranslatedTextFallsBackToEnglish() {
        let localization = Localization(defaults: InMemoryDefaults())
        localization.preference = .simplifiedChinese
        // The test bundle carries no zh-Hans.lproj, so every key is missing.
        #expect(localization.string("Pin the Dock") == "Pin the Dock")
    }

    @Test func preferenceIsRemembered() {
        let defaults = InMemoryDefaults()
        let first = Localization(defaults: defaults)
        #expect(first.preference == .system)

        first.preference = .simplifiedChinese
        let second = Localization(defaults: defaults)
        #expect(second.preference == .simplifiedChinese)
        #expect(second.resolved == .simplifiedChinese)
    }

    @Test func systemResolvesToAConcreteLanguage() {
        let localization = Localization(defaults: InMemoryDefaults())
        #expect(localization.resolved == .english || localization.resolved == .simplifiedChinese)
    }

    @Test func localeFollowsTheChosenLanguage() {
        let localization = Localization(defaults: InMemoryDefaults())

        localization.preference = .simplifiedChinese
        #expect(localization.locale.identifier.hasPrefix("zh"))

        localization.preference = .english
        #expect(localization.locale.identifier.hasPrefix("en"))
    }

    /// The table that ships with the app has to parse, and has to cover the interface.
    @Test func shippedChineseTableCoversTheInterface() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")

        let table = Localization.loadTable(url: url)
        #expect(table.count > 200)
        #expect(table["Pin the Dock"] == "固定程序坞")
        #expect(table["Language"] == "语言")
        #expect(table["Show in menu bar"] == "在菜单栏中显示")
        #expect(table.values.allSatisfy { !$0.isEmpty })
    }

    /// Placeholders survive translation, so `String(format:)` can fill them in.
    @Test func placeholdersSurviveTranslation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let table = Localization.loadTable(url: url)

        let template = try #require(table["DockPin %@ is available"])
        #expect(String(format: template, "2.3").contains("2.3"))
        #expect(template.contains("%@"))
    }
}
