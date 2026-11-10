import Foundation
import CoreGraphics
import CryptoKit
import OSLog

final class ProfileManager {
    /// Something went wrong reading the stored profiles. The stored data is never overwritten
    /// because of it; a copy is kept under a backup key.
    enum LoadIssue: Equatable {
        /// Some profiles were unreadable and left out.
        case skippedProfiles(Int)
        /// Nothing could be read.
        case unreadable
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.green2grey.DockPin", category: "profiles")

    private enum Key {
        static let profiles = "v2.profiles"
        static let profilesBackup = "v2.profilesUnreadableBackup"
        static let loadIssueAcknowledged = "v2.profilesLoadIssueAcknowledged"
        static let activeProfileID = "v2.activeProfileID"
        static let setupCompleted = "v2.setupCompleted"
        static let autoSwitchEnabled = "v2.autoSwitchEnabled"
        static let manualHoldEnabled = "v2.manualHoldEnabled"
        static let resetNoticeShown = "v2.resetNoticeShown"
        static let hidesMenuBarIcon = "v2.hidesMenuBarIcon"
        static let lastRunVersion = "v2.lastRunVersion"
        static let displayNames = "v2.displayNames"
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    private(set) var profiles: [DockProfile] = []

    var setupCompleted: Bool {
        get { defaults.bool(forKey: Key.setupCompleted) }
        set { defaults.set(newValue, forKey: Key.setupCompleted) }
    }

    var autoSwitchEnabled: Bool {
        get {
            if defaults.object(forKey: Key.autoSwitchEnabled) == nil { return true }
            return defaults.bool(forKey: Key.autoSwitchEnabled)
        }
        set { defaults.set(newValue, forKey: Key.autoSwitchEnabled) }
    }

    var manualHoldEnabled: Bool {
        get { defaults.bool(forKey: Key.manualHoldEnabled) }
        set { defaults.set(newValue, forKey: Key.manualHoldEnabled) }
    }

    var resetNoticeShown: Bool {
        get { defaults.bool(forKey: Key.resetNoticeShown) }
        set { defaults.set(newValue, forKey: Key.resetNoticeShown) }
    }

    /// The version of DockPin that last ran here, used to notice an update. Versions before 2.2
    /// never recorded it.
    var lastRunVersion: String? {
        get { defaults.string(forKey: Key.lastRunVersion) }
        set { defaults.set(newValue, forKey: Key.lastRunVersion) }
    }

    var hidesMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.hidesMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.hidesMenuBarIcon) }
    }

    /// Names of displays seen so far, keyed by `DisplayStableID.storageKey`, so a display a
    /// profile refers to can still be named while it's unplugged.
    private(set) var displayNames: [String: String] {
        get { defaults.dictionary(forKey: Key.displayNames) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.displayNames) }
    }

    func rememberDisplayNames(from snapshot: DisplaySnapshot) {
        var names = displayNames
        var changed = false
        for display in snapshot.displays where names[display.stableID.storageKey] != display.localizedName {
            names[display.stableID.storageKey] = display.localizedName
            changed = true
        }
        if changed { displayNames = names }
    }

    var activeProfileID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Key.activeProfileID) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: Key.activeProfileID)
            } else {
                defaults.removeObject(forKey: Key.activeProfileID)
            }
        }
    }

    var activeProfile: DockProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Whether the last `load()` found stored profiles it could not read at all. While this is
    /// true the stored data is still in place, so nothing should replace it without the user
    /// asking.
    private(set) var storedProfilesUnreadable = false
    /// The problem found by the last `load()`, until the user has been told about it once.
    private(set) var unacknowledgedLoadIssue: LoadIssue?
    private var loadIssueFingerprint: String?

    func load() {
        unacknowledgedLoadIssue = nil
        loadIssueFingerprint = nil
        storedProfilesUnreadable = false

        guard let data = defaults.data(forKey: Key.profiles) else {
            profiles = []
            return
        }

        var issue: LoadIssue?
        do {
            let stored = try decoder.decode(StoredProfiles.self, from: data)
            profiles = stored.profiles
            if stored.skippedCount > 0 {
                issue = .skippedProfiles(stored.skippedCount)
                logger.error("Skipped \(stored.skippedCount) unreadable stored profile(s)")
            }
        } catch {
            profiles = []
            issue = .unreadable
            storedProfilesUnreadable = true
            logger.error("Stored profiles are unreadable: \(String(describing: error), privacy: .public)")
        }

        for idx in profiles.indices {
            profiles[idx].sanitize()
        }

        if let issue {
            // Keep what was stored. It stays under the main key until the user next changes a
            // profile, and under the backup key after that.
            defaults.set(data, forKey: Key.profilesBackup)
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if defaults.string(forKey: Key.loadIssueAcknowledged) != fingerprint {
                unacknowledgedLoadIssue = issue
                loadIssueFingerprint = fingerprint
            }
            return
        }

        // A clean read: store the sanitized form if it differs, and drop a dangling selection.
        if let encoded = try? encoder.encode(profiles), encoded != data {
            defaults.set(encoded, forKey: Key.profiles)
        }
        if let id = activeProfileID, !profiles.contains(where: { $0.id == id }) {
            activeProfileID = nil
        }
    }

    /// Records that the user has seen the current load issue, so it isn't reported again for the
    /// same stored data.
    func acknowledgeLoadIssue() {
        if let loadIssueFingerprint {
            defaults.set(loadIssueFingerprint, forKey: Key.loadIssueAcknowledged)
        }
        unacknowledgedLoadIssue = nil
        loadIssueFingerprint = nil
    }

    func addProfile(_ profile: DockProfile, makeActive: Bool = true) {
        profiles.append(profile)
        storedProfilesUnreadable = false
        persistProfiles()
        if makeActive {
            activeProfileID = profile.id
        }
    }

    func updateProfile(id: UUID, _ mutate: (inout DockProfile) -> Void) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&profiles[idx])
        profiles[idx].sanitize()
        persistProfiles()
    }

    func setActiveProfile(id: UUID, manualHold: Bool) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        if manualHold { manualHoldEnabled = true }
    }

    func deleteProfile(id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (activeProfileID == id)

        profiles.remove(at: idx)
        persistProfiles()

        if profiles.isEmpty {
            activeProfileID = nil
            manualHoldEnabled = false
            setupCompleted = false
            return
        }

        if wasActive {
            let newIndex = min(idx, profiles.count - 1)
            activeProfileID = profiles[newIndex].id
        }
    }

    func renameProfile(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProfile(id: id) { $0.name = trimmed }
    }

    /// A name no existing profile has, built from `base` ("Profile", "Profile 2", ...).
    func unusedProfileName(base: String = "Profile") -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    func saveCurrentAsProfile(name: String, snapshot: DisplaySnapshot) -> DockProfile? {
        guard var base = activeProfile else { return nil }
        base.id = UUID()
        base.name = name
        base.triggerRequirements = Self.triggerRequirements(for: snapshot, mirroringPolicy: base.mirroringPolicy)
        base.sanitize()
        addProfile(base, makeActive: true)
        manualHoldEnabled = true
        return base
    }

    // MARK: - Auto-switch

    /// The display setup a profile created right now should auto-activate for: every external
    /// display currently connected.
    ///
    /// The built-in display is left out on purpose. It says nothing about where a laptop is, and
    /// requiring it would stop a profile made with the lid open from matching in clamshell mode.
    /// With no external display there is nothing to tell setups apart, so there is no trigger.
    static func triggerRequirements(
        for snapshot: DisplaySnapshot,
        mirroringPolicy: MirroringPolicy
    ) -> [DisplayStableID: Int]? {
        var requirements: [DisplayStableID: Int] = [:]
        for display in snapshot.filtered(for: mirroringPolicy) where !display.isBuiltIn {
            requirements[display.stableID, default: 0] += 1
        }
        return requirements.isEmpty ? nil : requirements
    }

    /// Makes the displays connected right now the profile's auto-switch trigger, replacing
    /// whatever it had. With no external display connected the profile ends up with no trigger.
    func relinkTrigger(id: UUID, snapshot: DisplaySnapshot) {
        updateProfile(id: id) {
            $0.triggerRequirements = Self.triggerRequirements(for: snapshot, mirroringPolicy: $0.mirroringPolicy)
        }
    }

    /// Gives a profile that has no trigger yet (anything made before v2.2) the current display
    /// setup as its trigger. Called when the user picks the profile by hand, which is the one
    /// moment DockPin knows the profile belongs with these displays.
    func learnTriggerIfMissing(id: UUID, snapshot: DisplaySnapshot) {
        guard let profile = profiles.first(where: { $0.id == id }),
              profile.triggerRequirements == nil,
              let requirements = Self.triggerRequirements(for: snapshot, mirroringPolicy: profile.mirroringPolicy)
        else { return }
        updateProfile(id: id) { $0.triggerRequirements = requirements }
    }

    func resolveAllowedDisplayIDs(for profile: DockProfile, snapshot: DisplaySnapshot) -> Set<CGDirectDisplayID> {
        var ids: Set<CGDirectDisplayID> = []
        for stableID in profile.allowedDisplays {
            ids.formUnion(snapshot.displayIDs(matching: stableID, mirroringPolicy: profile.mirroringPolicy))
        }
        return ids
    }

    func bestAutoSwitchMatch(snapshot: DisplaySnapshot) -> DockProfile? {
        guard setupCompleted, autoSwitchEnabled, !manualHoldEnabled else { return nil }

        let candidates: [(profile: DockProfile, score: Int)] = profiles.compactMap { profile in
            guard let reqs = profile.triggerRequirements, !reqs.isEmpty else { return nil }

            let exact = snapshot.exactCounts(mirroringPolicy: profile.mirroringPolicy)
            let vendorModel = snapshot.vendorModelCounts(mirroringPolicy: profile.mirroringPolicy)

            var totalRequired = 0
            var serialExactBonus = 0

            for (stableID, count) in reqs {
                if stableID.hasSerial {
                    if (exact[stableID] ?? 0) < count { return nil }
                    serialExactBonus += 1
                    totalRequired += count
                } else {
                    if (vendorModel[stableID.vendorModelKey] ?? 0) < count { return nil }
                    totalRequired += count
                }
            }

            let score = (totalRequired * 100) + serialExactBonus
            return (profile: profile, score: score)
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }

        let tied = candidates.filter { $0.score == best.score }
        if tied.count > 1 {
            let names = tied.map { $0.profile.name }.joined(separator: ", ")
            logger.debug("Auto-switch tie (score \(best.score)): \(names, privacy: .public)")
            return nil
        }

        return best.profile
    }

    private func persistProfiles() {
        do {
            defaults.set(try encoder.encode(profiles), forKey: Key.profiles)
        } catch {
            logger.error("Couldn't save profiles: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The stored profile list, read one profile at a time so a single bad entry doesn't take the
/// rest with it.
private struct StoredProfiles: Decodable {
    var profiles: [DockProfile] = []
    var skippedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                profiles.append(try container.decode(DockProfile.self))
            } catch {
                skippedCount += 1
                // A failed decode leaves the container on the same element; consume it.
                _ = try container.decode(AnyValue.self)
            }
        }
    }

    private struct AnyValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
