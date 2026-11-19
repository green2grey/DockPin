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

    /// A recorded key keeps the layout-dependent name it was given, but special keys are
    /// looked up again so their name follows the interface language.
    @Test func recordedSpecialKeysTakeTheirNameFromTheKeyCode() {
        let space = CustomOverrideKey(keyCode: 49, label: "old name")
        #expect(space.displayLabel == KeyNames.label(keyCode: 49))
        #expect(space.doesSomethingWhenHeld)

        let character = CustomOverrideKey(keyCode: 0, label: "A")
        #expect(character.displayLabel == "A")
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

    // MARK: - The shipped table against the source

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func shippedChineseTable() -> [String: String] {
        Localization.loadTable(
            url: repositoryRoot.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        )
    }

    /// The text a Swift string literal stands for: `\u{2318}` is ⌘ and `\"` is a quote. The
    /// table is keyed by that text, not by what is typed between the quotes.
    private static func unescaped(_ literal: String) -> String {
        var result = ""
        var rest = Substring(literal)
        while let backslash = rest.firstIndex(of: "\\") {
            result += rest[..<backslash]
            rest = rest[rest.index(after: backslash)...]
            guard let escape = rest.first else { break }
            rest = rest.dropFirst()
            switch escape {
            case "n": result += "\n"
            case "t": result += "\t"
            case "u":
                guard rest.first == "{", let close = rest.firstIndex(of: "}"),
                      let value = UInt32(rest[rest.index(after: rest.startIndex)..<close], radix: 16),
                      let scalar = Unicode.Scalar(value)
                else { continue }
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: close)...]
            default:
                result.append(escape)
            }
        }
        return result + rest
    }

    /// Every key written as `L("…")` in the source, with the file it was found in.
    private static func keysInSources() throws -> [String: String] {
        let sources = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let call = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys: [String: String] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let literal = Range(match.range(at: 1), in: text) else { continue }
                keys[unescaped(String(text[literal]))] = url.lastPathComponent
            }
        }
        return keys
    }

    /// How many arguments a format string takes: `%@`, or the positional `%1$@`.
    private static func placeholderCount(_ text: String) -> Int {
        guard let placeholder = try? NSRegularExpression(pattern: #"%(\d+\$)?@"#) else { return 0 }
        return placeholder.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Every string the interface asks for has a translation. One that is missing is shown in
    /// English, in the middle of a Chinese window.
    @Test func everyInterfaceStringHasATranslation() throws {
        let table = Self.shippedChineseTable()
        let keys = try Self.keysInSources()
        // If L("…") ever changes shape, finding no keys must not pass for finding no gaps.
        #expect(keys.count > 200)

        let missing = keys
            .filter { table[$0.key] == nil }
            .map { "\($0.value): \($0.key)" }
            .sorted()
        #expect(missing.isEmpty, "No zh-Hans translation for: \(missing)")
    }

    /// A translation takes the same arguments as its English. With one placeholder too many,
    /// `String(format:)` reads an argument that was never passed.
    @Test func translationsKeepTheirPlaceholders() {
        let mismatched = Self.shippedChineseTable()
            .filter { Self.placeholderCount($0.key) != Self.placeholderCount($0.value) }
            .keys.sorted()
        #expect(mismatched.isEmpty, "Placeholders differ from the English in: \(mismatched)")
    }

    /// On its own an edge is a label ("Bottom"); inside a sentence it is not ("bottom edge").
    @Test func edgeNamesAreCapitalizedOnlyOnTheirOwn() {
        #expect(DockEdge.allCases.map(\.label) == ["Left", "Bottom", "Right"])
        #expect(DockEdge.allCases.map(\.nameInSentence) == ["left", "bottom", "right"])
        #expect(DockEdge.bottom.requirementDescription == "bottom edge")
    }

    /// With zh-Hans.lproj as the only localization in the bundle and no development region,
    /// macOS runs the app in Chinese for everyone: AppKit's own buttons and menus turn Chinese,
    /// and so does `Locale.current`. Naming English as the development region prevents that.
    @Test func theBundleNamesEnglishAsItsOwnLanguage() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let info = try #require(plist as? [String: Any])
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
    }
}
