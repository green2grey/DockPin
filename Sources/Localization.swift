import Foundation
import SwiftUI

/// A language the interface can be shown in.
///
/// The stored preference may be `.system`, in which case the language follows the
/// first preferred language of the system.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// What `.system` resolves to right now.
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// The name shown in the language picker, in that language's own words.
    var displayName: String {
        switch self {
        case .system: return L("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// Looks up interface strings in the language the user chose.
///
/// Translations live in `Resources/<language>.lproj/Localizable.strings`; the English
/// text in the source is the key. A missing translation falls back to the key, which is
/// what makes a half-translated build still readable.
final class Localization: ObservableObject {
    static let shared = Localization()

    /// UserDefaults key holding the chosen language.
    static let defaultsKey = "v2.appLanguage"

    /// The chosen language. Changing it publishes so SwiftUI redraws, and is remembered.
    @Published var preference: AppLanguage {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.defaultsKey)
            cachedTable = nil
        }
    }

    private let defaults: UserDefaults
    private var cachedTable: [String: String]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey) ?? ""
        preference = AppLanguage(rawValue: stored) ?? .system
    }

    /// The language actually used once `.system` is resolved.
    var resolved: AppLanguage {
        preference == .system ? AppLanguage.systemDefault : preference
    }

    /// The text for `key`, in the resolved language.
    func string(_ key: String) -> String {
        guard resolved == .simplifiedChinese else { return key }
        return chineseTable[key] ?? key
    }

    private var chineseTable: [String: String] {
        if let cachedTable { return cachedTable }
        let table = Self.loadTable(
            url: Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                 subdirectory: nil, localization: "zh-Hans")
        )
        cachedTable = table
        return table
    }

    /// Reads a `.strings` file into a dictionary. Missing or unreadable files give an empty
    /// table, so the interface falls back to English rather than failing to draw.
    static func loadTable(url: URL?, defaults: UserDefaults? = nil) -> [String: String] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let table = plist as? [String: String]
        else { return [:] }
        return table
    }
}

/// The localized form of an English interface string.
///
///     L("Pin the Dock")                  → "固定程序坞"
///     L("Pinned to %@", displayName)     → "已固定到 …"
///
/// The English argument is the key. With `.system` or `.english` it is returned as is,
/// which keeps call sites readable and makes the source the English translation.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Localization.shared.string(key)
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}
