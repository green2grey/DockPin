import AppKit
import CoreGraphics
import SwiftUI

struct StatusBarState {
    var displaySnapshot: DisplaySnapshot
    var profiles: [DockProfile]
    var activeProfileID: UUID?
    var activeProfile: DockProfile?
    var dockEdge: DockEdge
    var reachability: [CGDirectDisplayID: DisplayEdgeReachability]
    var resolvedAllowedDisplayIDs: Set<CGDirectDisplayID>
    var isConfigured: Bool
    var isAccessibilityTrusted: Bool
    var isLoginItemEnabled: Bool
    var autoSwitchEnabled: Bool
    var manualHoldEnabled: Bool
    var toggleDisabledReason: String?
    var reanchorDisabledReason: String?
    var blockedSelectionSummary: String?

    static let empty = StatusBarState(
        displaySnapshot: DisplaySnapshot(displays: []),
        profiles: [],
        activeProfileID: nil,
        activeProfile: nil,
        dockEdge: .bottom,
        reachability: [:],
        resolvedAllowedDisplayIDs: [],
        isConfigured: false,
        isAccessibilityTrusted: false,
        isLoginItemEnabled: false,
        autoSwitchEnabled: true,
        manualHoldEnabled: false,
        toggleDisabledReason: "Set up DockPin first",
        reanchorDisabledReason: "Set up DockPin first",
        blockedSelectionSummary: nil
    )
}

@MainActor
final class StatusBarModel: ObservableObject {
    @Published private(set) var state: StatusBarState = .empty

    func update(_ state: StatusBarState) {
        self.state = state
    }
}

@MainActor
protocol StatusBarActions: AnyObject {
    func statusBarToggleEnabled()
    func statusBarToggleAllowedDisplay(_ stableID: DisplayStableID)
    func statusBarSetOverrideModifier(_ modifier: ModifierOption)
    func statusBarSelectProfile(_ id: UUID)
    func statusBarToggleAutoSwitch()
    func statusBarResumeAutoSwitching()
    func statusBarSaveCurrentAsProfile()
    func statusBarReanchorDockNow()
    func statusBarShowSetup()
    func statusBarShowHelp()
    func statusBarCheckForUpdates()
    func statusBarToggleStartup()
    func statusBarQuit()
}

struct DockPinPopoverView: View {
    @ObservedObject var model: StatusBarModel
    let actions: any StatusBarActions

    var body: some View {
        let state = model.state

        VStack(alignment: .leading, spacing: 12) {
            header(state)
            Divider()
            primaryAction(state)
            dockEdge(state)
            displays(state)
            modifierPicker(state)
            profiles(state)
            Divider()
            footerActions(state)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func header(_ state: StatusBarState) -> some View {
        HStack(alignment: .center) {
            Image(systemName: state.activeProfile?.isEnabled == true ? "pin.fill" : "pin")
                .foregroundStyle(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("DockPin — \(state.activeProfile?.name ?? "Not configured")")
                    .font(.headline)
                Text(state.isAccessibilityTrusted ? "Accessibility granted" : "Accessibility needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill(state)
        }
    }

    private func statusPill(_ state: StatusBarState) -> some View {
        let label: String = {
            if !state.isConfigured { return "Setup" }
            if !state.isAccessibilityTrusted { return "Needs Access" }
            return state.activeProfile?.isEnabled == true ? "Enabled" : "Disabled"
        }()

        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(statusColor(state).opacity(0.16)))
            .foregroundStyle(statusColor(state))
            .accessibilityLabel("DockPin status: \(label)")
    }

    private func statusColor(_ state: StatusBarState) -> Color {
        if !state.isConfigured || !state.isAccessibilityTrusted { return .orange }
        return state.activeProfile?.isEnabled == true ? .green : .gray
    }

    private func primaryAction(_ state: StatusBarState) -> some View {
        Button {
            actions.statusBarToggleEnabled()
        } label: {
            Text(state.activeProfile?.isEnabled == true ? "Disable DockPin" : "Enable DockPin")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("e")
        .disabled(state.toggleDisabledReason != nil)
        .help(state.toggleDisabledReason ?? "")
    }

    private func dockEdge(_ state: StatusBarState) -> some View {
        Label("Current Dock Edge: \(state.dockEdge.label)", systemImage: "dock.rectangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func displays(_ state: StatusBarState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Displays")
                .font(.subheadline.weight(.semibold))

            let displays = state.displaySnapshot.filtered(for: state.activeProfile?.mirroringPolicy ?? .ignoreMirroredSecondaries)
            if displays.isEmpty {
                Text("No displays detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if displays.count < 2 {
                Text("Connect a second display to use DockPin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(displays, id: \.displayID) { display in
                displayRow(display, state: state)
            }

            if let warning = state.blockedSelectionSummary {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning: \(warning)")
            }
        }
    }

    private func displayRow(_ display: DisplayDescriptor, state: StatusBarState) -> some View {
        let isAllowed = state.activeProfile?.allowedDisplays.contains(display.stableID) == true
        let reachability = state.reachability[display.displayID]
        let isReachable = reachability?.isReachable ?? true
        let status = displayStatus(isAllowed: isAllowed, isReachable: isReachable)

        return Toggle(isOn: Binding(
            get: { isAllowed },
            set: { _ in actions.statusBarToggleAllowedDisplay(display.stableID) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.localizedName)
                    .lineLimit(1)
                Spacer()
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(isReachable ? .secondary : .orange)
            }
        }
        .disabled(!state.isConfigured || state.activeProfile == nil)
        .help(reachability?.blockedReason ?? "")
    }

    private func displayStatus(isAllowed: Bool, isReachable: Bool) -> String {
        if isAllowed && isReachable { return "allowed" }
        if isAllowed { return "blocked" }
        if !isReachable { return "edge blocked" }
        return "available"
    }

    private func modifierPicker(_ state: StatusBarState) -> some View {
        Picker(
            "Override Modifier",
            selection: Binding(
                get: { state.activeProfile?.overrideModifier ?? .option },
                set: { actions.statusBarSetOverrideModifier($0) }
            )
        ) {
            ForEach(ModifierOption.allCases, id: \.rawValue) { modifier in
                Text(modifier.label).tag(modifier)
            }
        }
        .disabled(!state.isConfigured || state.activeProfile == nil)
    }

    private func profiles(_ state: StatusBarState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.subheadline.weight(.semibold))

            if state.profiles.isEmpty {
                Text("No profiles yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Active Profile",
                    selection: Binding<UUID?>(
                        get: { state.activeProfileID },
                        set: { id in
                            if let id {
                                actions.statusBarSelectProfile(id)
                            }
                        }
                    )
                ) {
                    ForEach(state.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack {
                Button("Save Current…") {
                    actions.statusBarSaveCurrentAsProfile()
                }
                .disabled(!state.isConfigured)

                Toggle(isOn: Binding(
                    get: { state.autoSwitchEnabled },
                    set: { _ in actions.statusBarToggleAutoSwitch() }
                )) {
                    Text("Auto-switch")
                }
                .disabled(!state.isConfigured)
            }

            if state.manualHoldEnabled {
                Button("Resume Auto-switching") {
                    actions.statusBarResumeAutoSwitching()
                }
                .font(.caption)
            }
        }
    }

    private func footerActions(_ state: StatusBarState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Re-anchor Dock Now") {
                    actions.statusBarReanchorDockNow()
                }
                .disabled(state.reanchorDisabledReason != nil)
                .help(state.reanchorDisabledReason ?? "")

                Spacer()

                Button("Set Up…") {
                    actions.statusBarShowSetup()
                }
            }

            HStack(spacing: 8) {
                Button("Help…") {
                    actions.statusBarShowHelp()
                }
                Button("Check for Updates…") {
                    actions.statusBarCheckForUpdates()
                }
            }

            HStack {
                Button(state.isLoginItemEnabled ? "Disable Launch at Startup" : "Launch at Startup") {
                    actions.statusBarToggleStartup()
                }
                Spacer()
                Button("Quit DockPin") {
                    actions.statusBarQuit()
                }
                .keyboardShortcut("q")
            }
        }
    }
}
