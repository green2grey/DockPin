import SwiftUI

/// Where the Dock is allowed, and whether DockPin is holding it there.
struct DisplaysPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var recorder = KeyRecorder()

    private var state: SettingsState { model.state }

    var body: some View {
        Form {
            if state.hasProfile {
                pinSection
                displaysSection
                optionsSection
                reanchorSection
            } else {
                setupSection
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    // MARK: - Sections

    private var pinSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.pinningEnabled },
                set: { model.actions?.setPinningEnabled($0) }
            )) {
                RowLabel(
                    title: "Pin the Dock",
                    caption: state.pinningEnabled
                        ? state.statusDetail
                        : (state.enableBlockedReason ?? state.statusDetail)
                )
            }
            .disabled(!state.pinningEnabled && state.enableBlockedReason != nil)

            if state.lockStatus == .needsAccessibility {
                LabeledContent {
                    Button("Open System Settings…") { model.actions?.openAccessibilitySettings() }
                } label: {
                    IconRowLabel(
                        symbolName: "exclamationmark.triangle.fill",
                        symbolStyle: .yellow,
                        title: "Accessibility access needed",
                        caption: "DockPin can’t keep the Dock in place without it."
                    )
                }
            }
        }
    }

    private var displaysSection: some View {
        Section {
            ForEach(state.displays) { display in
                Toggle(isOn: Binding(
                    get: { display.isAllowed },
                    set: { model.actions?.setDisplay(display, allowed: $0) }
                )) {
                    IconRowLabel(
                        symbolName: display.isBuiltIn ? "laptopcomputer" : "display",
                        symbolStyle: display.isConnected ? .primary : .secondary,
                        title: display.name,
                        caption: display.caption,
                        captionStyle: display.isAllowed && display.blockedReason != nil ? .orange : .secondary
                    )
                }
                .disabled(display.isAllowed && !display.canDisallow)
                .help(display.isAllowed && !display.canDisallow ? "At least one display has to stay allowed." : "")
            }
        } header: {
            Text("Allow the Dock on")
        } footer: {
            SectionFootnote(state.connectedDisplayCount < 2
                ? "Connect a second display to use DockPin."
                : "The Dock stays on the displays you allow. At least one has to stay allowed.")
        }
    }

    private var optionsSection: some View {
        Section {
            Picker(selection: Binding(
                // While a first custom key is being recorded the menu already reads "Custom…",
                // but the profile isn't touched until a key has actually been pressed.
                get: { recorder.isRecording ? .custom : state.overrideChoice },
                set: { choice in
                    switch choice {
                    case .modifier(let modifier):
                        recorder.stop()
                        model.actions?.setOverrideModifier(modifier)
                    case .custom:
                        if state.customOverrideKey == nil { recordKey() }
                    }
                }
            )) {
                ForEach(ModifierOption.allCases, id: \.self) { modifier in
                    Text(modifier.label).tag(OverrideChoice.modifier(modifier))
                }
                Divider()
                Text("Custom…").tag(OverrideChoice.custom)
            } label: {
                RowLabel(title: "Override key", caption: "Hold it to move the Dock to any display.")
            }

            if recorder.isRecording || state.overrideChoice == .custom {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(recorder.isRecording ? "Press a key…" : (state.customOverrideKey?.label ?? "None"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(recorder.isRecording ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(recorder.isRecording ? Color.accentColor : Color.primary.opacity(0.12))
                            )
                        if recorder.isRecording {
                            Button("Cancel") { recorder.stop() }
                        } else {
                            Button("Record…") { recordKey() }
                        }
                    }
                } label: {
                    RowLabel(
                        title: "Custom key",
                        caption: recorder.isRecording
                            ? "Press the key to use, or Escape to cancel."
                            : (state.customOverrideKey?.doesSomethingWhenHeld == true
                                ? "This key still does its usual job while you hold it. A function key or a right-hand modifier avoids that."
                                : nil)
                    )
                }
            }

            LabeledContent {
                Text(state.dockEdge.label)
            } label: {
                RowLabel(
                    title: "Dock position",
                    caption: "Set in System Settings → Desktop & Dock. DockPin follows it."
                )
            }
        }
    }

    private func recordKey() {
        recorder.start { key in
            model.actions?.setCustomOverrideKey(key)
        }
    }

    private var reanchorSection: some View {
        Section {
            LabeledContent {
                Button("Re-anchor Now") { model.actions?.reanchorNow() }
                    .disabled(state.reanchorDisabledReason != nil)
            } label: {
                RowLabel(
                    title: "Re-anchor the Dock",
                    caption: state.reanchorDisabledReason
                        ?? "Brings the Dock back to the allowed display by briefly moving the pointer to its edge."
                )
            }
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.storedProfilesUnreadable ? "Your saved profiles couldn’t be read" : "Set up DockPin")
                    .font(.headline)
                Text(state.storedProfilesUnreadable
                    ? "DockPin kept a backup copy of the saved data. Start fresh to create a new profile."
                    : "Create a profile, choose the displays the Dock is allowed on, then turn on pinning.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(state.storedProfilesUnreadable ? "Start Fresh" : "Set Up") {
                    model.actions?.createFirstProfile()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 6)
        }
    }
}
