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

