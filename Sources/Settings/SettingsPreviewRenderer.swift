#if DOCKPIN_DEV
import AppKit
import SwiftUI

/// Dev builds only: draws the settings window with made-up data into PNG files, so the design
/// can be reviewed without touching real settings or showing a window.
///
///     "build/DockPin Dev.app/Contents/MacOS/DockPin" --render-settings <directory>
@MainActor
enum SettingsPreviewRenderer {
    static func render(to directory: URL, appearance: NSAppearance.Name = .darkAqua) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scene in scenes {
            let model = SettingsModel()
            model.state = scene.state
            model.pane = scene.pane

            let window = SettingsWindowController.makeWindow(model: model)
            window.appearance = NSAppearance(named: appearance)
            // Far off any screen: it has to be ordered in for SwiftUI to draw, but shouldn't flash up.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))

            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(scene.name).png"))
            }
            window.orderOut(nil)
        }
    }

    private struct Scene {
        var name: String
        var pane: SettingsPane
        var state: SettingsState
    }

    private static var scenes: [Scene] {
        let laptop = DisplayStableID(vendorID: 1552, modelID: 41065, serial: 0)
        let monitor = DisplayStableID(vendorID: 1715, modelID: 13025, serial: 98307)
        let homeMonitor = DisplayStableID(vendorID: 4268, modelID: 53443, serial: 77)
        let names = [
            laptop.storageKey: "Built-in Retina Display",
            monitor.storageKey: "ASUS PG32UQ",
            homeMonitor.storageKey: "LG UltraFine",
        ]

        // A laptop with a larger monitor above it, hanging over on the right.
        let laptopFrame = CGRect(x: 0, y: 0, width: 2064, height: 1347)
        let monitorFrame = CGRect(x: -226, y: 1347, width: 2560, height: 1440)
        let snapshot = DisplaySnapshot(displays: [
            DisplayDescriptor(displayID: 1, stableID: laptop, localizedName: "Built-in Retina Display",
                              frame: laptopFrame, isBuiltIn: true, isMirroredSecondary: false),
            DisplayDescriptor(displayID: 5, stableID: monitor, localizedName: "ASUS PG32UQ",
                              frame: monitorFrame, isBuiltIn: false, isMirroredSecondary: false),
        ])
        let reachability = DisplayLayoutAnalyzer.reachabilityMap(snapshot: snapshot, edge: .bottom)

        let work = DockProfile(name: "Work", isEnabled: true, overrideModifier: .option,
                               allowedDisplays: [monitor], triggerRequirements: [monitor: 1])
        let home = DockProfile(name: "Home", isEnabled: true, overrideModifier: .option,
                               allowedDisplays: [homeMonitor], triggerRequirements: [homeMonitor: 1])
        let legacy = DockProfile(name: "Presenting", isEnabled: false, overrideModifier: .command,
                                 allowedDisplays: [laptop])

        func inputs(_ profiles: [DockProfile], active: DockProfile, status: LockStatus) -> SettingsState.Inputs {
            SettingsState.Inputs(
                profiles: profiles,
                activeProfileID: active.id,
                snapshot: snapshot,
                reachability: reachability,
                dockEdge: .bottom,
                lockStatus: status,
                dockDisplay: 5,
                displayNames: names,
                version: "2.2 (220)"
            )
        }

        let pinned = SettingsState(inputs([work, home, legacy], active: work, status: .locking))

        var waitingInputs = inputs([work, home, legacy], active: work, status: .needsAccessibility)
        waitingInputs.isAccessibilityTrusted = false
        waitingInputs.reanchorDisabledReason = "Grant Accessibility access first"

        var offProfile = work
        offProfile.isEnabled = false
        offProfile.allowedDisplays = [monitor, homeMonitor]
        offProfile.customOverrideKey = CustomOverrideKey(keyCode: 105, label: KeyNames.label(keyCode: 105))
        offProfile.sanitize()
        var offInputs = inputs([offProfile, home], active: offProfile, status: .disabled)
        offInputs.reanchorDisabledReason = "Turn on pinning first"

        var pausedInputs = inputs([work, home, legacy], active: work, status: .locking)
        pausedInputs.manualHoldEnabled = true

        var generalInputs = inputs([work, home], active: work, status: .locking)
        generalInputs.launchAtLogin = .on

        var hiddenInputs = generalInputs
        hiddenInputs.showsMenuBarIcon = false
        hiddenInputs.launchAtLogin = .needsApproval
        hiddenInputs.isAccessibilityTrusted = false

        func general(_ name: String, _ status: UpdateStatus) -> Scene {
            var updating = generalInputs
            updating.updateStatus = status
            updating.lastUpdateCheck = Date().addingTimeInterval(-3 * 3600)
            return Scene(name: name, pane: .general, state: SettingsState(updating))
        }

        return [
            general("8-update-idle", .idle),
            general("9-update-up-to-date", .upToDate("DockPin 2.2 is currently the newest version available.")),
            general("10-update-available", .available(UpdateInfo(version: "2.3", notes: [
                "Hide the menu bar icon and still get back to Settings.",
                "Custom override key: record any key, not only a modifier.",
                "Re-anchor Dock Now works again on current versions of macOS.",
                "Auto-switch Profiles now switches.",
            ]))),
            general("11-update-downloading", .downloading(fraction: 0.42)),
            general("12-update-ready", .readyToInstall),
            general("13-update-failed", .failed("The update feed couldn’t be reached. Check your internet connection and try again.")),
            Scene(name: "1-displays-pinned", pane: .displays, state: pinned),
            Scene(name: "2-displays-needs-access", pane: .displays, state: SettingsState(waitingInputs)),
            Scene(name: "3-displays-off", pane: .displays, state: SettingsState(offInputs)),
            Scene(name: "4-displays-first-run", pane: .displays, state: SettingsState()),
            Scene(name: "5-profiles", pane: .profiles, state: SettingsState(pausedInputs)),
            Scene(name: "6-general", pane: .general, state: SettingsState(generalInputs)),
            Scene(name: "7-general-hidden-icon", pane: .general, state: SettingsState(hiddenInputs)),
        ]
    }
}
#endif
