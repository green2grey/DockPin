import Foundation
import CoreGraphics
import OSLog

final class ProfileManager {
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.green2grey.DockPin", category: "profiles")

    private enum Key {
        static let profiles = "v2.profiles"
        static let activeProfileID = "v2.activeProfileID"
        static let setupCompleted = "v2.setupCompleted"
        static let autoSwitchEnabled = "v2.autoSwitchEnabled"
        static let manualHoldEnabled = "v2.manualHoldEnabled"
        static let resetNoticeShown = "v2.resetNoticeShown"
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

    func load() {
        if let data = defaults.data(forKey: Key.profiles),
           let decoded = try? decoder.decode([DockProfile].self, from: data)
        {
            profiles = decoded
        } else {
            profiles = []
        }

        for idx in profiles.indices {
            profiles[idx].sanitize()
        }
        persistProfiles()

        if let id = activeProfileID, !profiles.contains(where: { $0.id == id }) {
            activeProfileID = nil
        }
    }

    func addProfile(_ profile: DockProfile, makeActive: Bool = true) {
        profiles.append(profile)
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

    func saveCurrentAsProfile(name: String) -> DockProfile? {
        guard var base = activeProfile else { return nil }
        base.id = UUID()
        base.name = name
        base.triggerRequirements = nil
        base.sanitize()
        addProfile(base, makeActive: true)
        manualHoldEnabled = true
        return base
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
        if let data = try? encoder.encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
    }
}
