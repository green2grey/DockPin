import Foundation

struct DockProfile: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var overrideModifier: ModifierOption
    var allowedDisplays: Set<DisplayStableID>
    var triggerRequirements: [DisplayStableID: Int]?
    var mirroringPolicy: MirroringPolicy

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool,
        overrideModifier: ModifierOption,
        allowedDisplays: Set<DisplayStableID>,
        triggerRequirements: [DisplayStableID: Int]? = nil,
        mirroringPolicy: MirroringPolicy = .ignoreMirroredSecondaries
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.overrideModifier = overrideModifier
        self.allowedDisplays = allowedDisplays
        self.triggerRequirements = triggerRequirements
        self.mirroringPolicy = mirroringPolicy
        sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, overrideModifier, allowedDisplays, triggerRequirements, mirroringPolicy
    }

    /// A profile is only unreadable when its identity or its display list is. Every other field
    /// falls back to a default, so a value written by a newer or older build (say, a modifier this
    /// build doesn't know) can't cost the user the whole profile.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        allowedDisplays = try container.decode(Set<DisplayStableID>.self, forKey: .allowedDisplays)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        overrideModifier = (try? container.decode(ModifierOption.self, forKey: .overrideModifier)) ?? .option
        triggerRequirements = try? container.decodeIfPresent(
            [DisplayStableID: Int].self,
            forKey: .triggerRequirements
        )
        mirroringPolicy = (try? container.decode(MirroringPolicy.self, forKey: .mirroringPolicy))
            ?? .ignoreMirroredSecondaries
        sanitize()
    }

    mutating func sanitize() {
        if var reqs = triggerRequirements {
            reqs = reqs.filter { $0.value > 0 }
            for (key, value) in reqs where key.hasSerial && value != 1 {
                reqs[key] = 1
            }
            triggerRequirements = reqs.isEmpty ? nil : reqs
        }
    }
}

