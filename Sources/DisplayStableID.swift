import AppKit
import CoreGraphics

struct DisplayStableID: Codable, Hashable, Sendable {
    var vendorID: UInt32
    var modelID: UInt32
    var serial: UInt32

    init(vendorID: UInt32, modelID: UInt32, serial: UInt32) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.serial = serial
    }

    init(displayID: CGDirectDisplayID) {
        vendorID = CGDisplayVendorNumber(displayID)
        modelID = CGDisplayModelNumber(displayID)
        serial = CGDisplaySerialNumber(displayID)
    }

    var hasSerial: Bool {
        serial != 0 && serial != 0xFFFF_FFFF
    }

    var vendorModelKey: VendorModelKey {
        VendorModelKey(vendorID: vendorID, modelID: modelID)
    }

    struct VendorModelKey: Codable, Hashable, Sendable {
        var vendorID: UInt32
        var modelID: UInt32
    }
}

struct DisplayDescriptor: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var stableID: DisplayStableID
    var localizedName: String
    var isBuiltIn: Bool
    var isMirroredSecondary: Bool
}

enum MirroringPolicy: String, Codable, CaseIterable, Sendable {
    case ignoreMirroredSecondaries
    case includeMirroredSecondaries
}

struct DisplaySnapshot: Sendable {
    var displays: [DisplayDescriptor]

    static func current() -> DisplaySnapshot {
        let displays: [DisplayDescriptor] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.dockPinDisplayID else { return nil }
            let stableID = DisplayStableID(displayID: displayID)

            let mirrors = CGDisplayMirrorsDisplay(displayID)
            let isMirroredSecondary = mirrors != 0 && mirrors != displayID

            return DisplayDescriptor(
                displayID: displayID,
                stableID: stableID,
                localizedName: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isMirroredSecondary: isMirroredSecondary
            )
        }

        return DisplaySnapshot(displays: displays)
    }

    func filtered(for mirroringPolicy: MirroringPolicy) -> [DisplayDescriptor] {
        switch mirroringPolicy {
        case .ignoreMirroredSecondaries:
            return displays.filter { !$0.isMirroredSecondary }
        case .includeMirroredSecondaries:
            return displays
        }
    }

    func exactCounts(mirroringPolicy: MirroringPolicy) -> [DisplayStableID: Int] {
        var result: [DisplayStableID: Int] = [:]
        for d in filtered(for: mirroringPolicy) {
            result[d.stableID, default: 0] += 1
        }
        return result
    }

    func vendorModelCounts(mirroringPolicy: MirroringPolicy) -> [DisplayStableID.VendorModelKey: Int] {
        var result: [DisplayStableID.VendorModelKey: Int] = [:]
        for d in filtered(for: mirroringPolicy) {
            result[d.stableID.vendorModelKey, default: 0] += 1
        }
        return result
    }

    func displayIDs(matching stableID: DisplayStableID, mirroringPolicy: MirroringPolicy) -> [CGDirectDisplayID] {
        if stableID.hasSerial {
            return filtered(for: mirroringPolicy)
                .filter { $0.stableID == stableID }
                .map(\.displayID)
        }

        let key = stableID.vendorModelKey
        return filtered(for: mirroringPolicy)
            .filter { $0.stableID.vendorModelKey == key }
            .map(\.displayID)
    }
}

