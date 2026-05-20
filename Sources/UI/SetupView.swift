import CoreGraphics
import SwiftUI

struct SetupView: View {
    let snapshot: DisplaySnapshot
    let dockEdge: DockEdge
    let onCancel: () -> Void
    let onFinish: (String, Set<DisplayStableID>, ModifierOption, Bool) -> Void

    @State private var profileName = ""
    @State private var selectedDisplays: Set<DisplayStableID> = []
    @State private var modifier: ModifierOption = .option
    @State private var enableAfterSetup = false
    @State private var showingBlockedEnableAlert = false
    @FocusState private var isProfileNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up DockPin")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Profile Name")
                    .font(.subheadline.weight(.semibold))
                TextField("My Profile", text: $profileName)
                    .focused($isProfileNameFocused)
                    .onSubmit(finishIfPossible)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Allow Dock on These Displays")
                    .font(.subheadline.weight(.semibold))

                List(displays, id: \.displayID) { display in
                    Toggle(isOn: binding(for: display)) {
                        displayLabel(display)
                    }
                    .accessibilityLabel("Allow Dock on \(display.localizedName)")
                }
                .frame(minHeight: 120, idealHeight: 160, maxHeight: 180)
            }

            if showsSerialLessNote {
                Label(
                    "Some displays can’t be uniquely identified; identical models may be treated as a group.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("Current macOS Dock edge: \(dockEdge.label). DockPin can only keep the Dock on displays with an exposed \(dockEdge.requirementDescription).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let warning = layoutWarning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning: \(warning)")
            }

            Picker("Override Modifier Key", selection: $modifier) {
                ForEach(ModifierOption.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option)
                }
            }

            Toggle("Enable DockPin after setup", isOn: $enableAfterSetup)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Finish") {
                    finishIfPossible()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canFinish)
            }
        }
        .padding(20)
        .onAppear {
            isProfileNameFocused = true
        }
        .alert(
            "Enable after setup needs an exposed \(dockEdge.requirementDescription).",
            isPresented: $showingBlockedEnableAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockedEnableMessage)
        }
    }

    private var displays: [DisplayDescriptor] {
        snapshot.filtered(for: .ignoreMirroredSecondaries)
    }

    private var reachability: [CGDirectDisplayID: DisplayEdgeReachability] {
        DisplayLayoutAnalyzer.reachabilityMap(snapshot: snapshot, edge: dockEdge)
    }

    private var selectedDescriptors: [DisplayDescriptor] {
        displays.filter { selectedDisplays.contains($0.stableID) }
    }

    private var trimmedProfileName: String {
        profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canFinish: Bool {
        !trimmedProfileName.isEmpty && !selectedDisplays.isEmpty
    }

    private var showsSerialLessNote: Bool {
        selectedDescriptors.contains { !$0.stableID.hasSerial }
    }

    private var blockedSelectedNames: [String] {
        selectedDescriptors
            .filter { reachability[$0.displayID]?.isReachable == false }
            .map(\.localizedName)
    }

    private var hasReachableSelectedDisplay: Bool {
        selectedDescriptors.contains { reachability[$0.displayID]?.isReachable == true }
    }

    private var layoutWarning: String? {
        guard !blockedSelectedNames.isEmpty else { return nil }
        return "\(dockEdge.label) edge is blocked on \(blockedSelectedNames.joined(separator: ", ")). Rearrange displays or switch macOS Dock position to a different edge before enabling DockPin for that display."
    }

    private var blockedEnableMessage: String {
        let summary = blockedSelectedNames.prefix(3).joined(separator: ", ")
        let suffix = blockedSelectedNames.count > 3 ? ", +\(blockedSelectedNames.count - 3) more" : ""
        return "Either uncheck \"Enable DockPin after setup\", rearrange your displays, or change the macOS Dock position before continuing. Blocked: \(summary)\(suffix)."
    }

    private func binding(for display: DisplayDescriptor) -> Binding<Bool> {
        Binding(
            get: { selectedDisplays.contains(display.stableID) },
            set: { isSelected in
                if isSelected {
                    selectedDisplays.insert(display.stableID)
                } else {
                    selectedDisplays.remove(display.stableID)
                }
            }
        )
    }

    private func displayLabel(_ display: DisplayDescriptor) -> some View {
        let info = reachability[display.displayID]
        let isReachable = info?.isReachable ?? true

        return HStack {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(.secondary)
            Text(display.localizedName)
            Spacer()
            if !isReachable {
                Label("blocked", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(display.localizedName) edge blocked")
                    .help(info?.blockedReason ?? "")
            }
        }
    }

    private func finishIfPossible() {
        guard canFinish else { return }
        if enableAfterSetup, !hasReachableSelectedDisplay {
            showingBlockedEnableAlert = true
            return
        }
        onFinish(trimmedProfileName, selectedDisplays, modifier, enableAfterSetup)
    }
}
