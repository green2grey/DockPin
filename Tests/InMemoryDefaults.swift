import Foundation
import Testing

/// Settings for one test, held in memory and never saved.
///
/// The tests used to give each test a real, throwaway settings domain and remove it afterwards.
/// That can't be cleaned up: a few seconds after a domain is emptied, the system writes an empty
/// file for it into ~/Library/Preferences, even when the test has already deleted the file and
/// exited. Every run left a few dozen files behind.
///
/// Only the three calls the rest of `UserDefaults` is built on are replaced; the typed ones
/// (`bool(forKey:)`, `set(true, forKey:)` and so on) go through them. `InMemoryDefaultsTests`
/// checks that for every kind of call the app makes.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        // The settings underneath are never read or written.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        // Real settings refuse anything that can't be saved in a property list. Keep that rule,
        // so a test still catches the app trying to store something that would fail for real.
        if let value {
            precondition(
                PropertyListSerialization.propertyList(value, isValidFor: .binary),
                "\(type(of: value)) can't be stored in UserDefaults"
            )
        }
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { _ = values.removeValue(forKey: defaultName) }
    }
}

@Suite struct InMemoryDefaultsTests {
    // If a typed call went around the in-memory store, a write would land in the real settings
    // underneath and a read would come back empty. Both are checked for every kind of value the
    // app saves: a flag, text, data and a dictionary.
    @Test func everyKindOfValueTheAppSavesStaysInMemory() {
        let defaults = InMemoryDefaults()
        let prefix = "DockPinTests.\(UUID().uuidString)"
        let keys = (flag: "\(prefix).flag", text: "\(prefix).text", data: "\(prefix).data", names: "\(prefix).names")
        let allKeys = [keys.flag, keys.text, keys.data, keys.names]
        // Tidy up only if something leaked: even removing a key that isn't there makes the system
        // write a settings file for the test runner.
        defer {
            for key in allKeys where UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        defaults.set(true, forKey: keys.flag)
        defaults.set("2.2", forKey: keys.text)
        defaults.set(Data([1, 2, 3]), forKey: keys.data)
        defaults.set(["1-2-3": "A Display"], forKey: keys.names)

        #expect(defaults.bool(forKey: keys.flag))
        #expect(defaults.string(forKey: keys.text) == "2.2")
        #expect(defaults.data(forKey: keys.data) == Data([1, 2, 3]))
        #expect(defaults.dictionary(forKey: keys.names) as? [String: String] == ["1-2-3": "A Display"])
        #expect(defaults.object(forKey: keys.flag) != nil)

        for key in allKeys {
            #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key) reached the real settings")
        }
    }

    @Test func removingAndSettingNothingBothClearAValue() {
        let defaults = InMemoryDefaults()
        defaults.set("a", forKey: "first")
        defaults.set("b", forKey: "second")

        defaults.removeObject(forKey: "first")
        defaults.set(nil as String?, forKey: "second")

        #expect(defaults.string(forKey: "first") == nil)
        #expect(defaults.object(forKey: "second") == nil)
    }

    @Test func nothingSavedReadsTheWayRealSettingsDo() {
        let defaults = InMemoryDefaults()
        #expect(!defaults.bool(forKey: "missing"))
        #expect(defaults.string(forKey: "missing") == nil)
        #expect(defaults.data(forKey: "missing") == nil)
        #expect(defaults.dictionary(forKey: "missing") == nil)
    }

    @Test func eachTestGetsItsOwn() {
        let first = InMemoryDefaults()
        let second = InMemoryDefaults()
        first.set(true, forKey: "flag")
        #expect(!second.bool(forKey: "flag"))
    }
}
