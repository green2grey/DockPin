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
                    title: L("Pin the Dock"),
                    caption: state.pinningEnabled
                        ? state.statusDetail
                        : (state.enableBlockedReason ?? state.statusDetail)
                )
            }
            .disabled(!state.pinningEnabled && state.enableBlockedReason != nil)

            if state.lockStatus == .needsAccessibility {
                LabeledContent {
                    Button(L("Open System Settings…")) { model.actions?.openAccessibilitySettings() }
                } label: {
                    IconRowLabel(
                        symbolName: "exclamationmark.triangle.fill",
                        symbolStyle: .yellow,
                        title: L("Accessibility access needed"),
                        caption: L("DockPin can’t keep the Dock in place without it.")
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
                .help(display.isAllowed && !display.canDisallow ? L("At least one display has to stay allowed.") : "")
            }
        } header: {
            Text(L("Allow the Dock on"))
        } footer: {
            SectionFootnote(state.connectedDisplayCount < 2
                ? L("Connect a second display to use DockPin.")
                : L("The Dock stays on the displays you allow. At least one has to stay allowed."))
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
                Text(L("Custom…")).tag(OverrideChoice.custom)
            } label: {
                RowLabel(title: L("Override key"), caption: L("Hold it to move the Dock to any display."))
            }

            if recorder.isRecording || state.overrideChoice == .custom {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(recorder.isRecording ? L("Press a key…") : (state.customOverrideKey?.label ?? L("None")))
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
                            Button(L("Cancel")) { recorder.stop() }
                        } else {
                            Button(L("Record…")) { recordKey() }
                        }
                    }
                } label: {
                    RowLabel(
                        title: L("Custom key"),
                        caption: recorder.isRecording
                            ? L("Press the key to use, or Escape to cancel.")
                            : (state.customOverrideKey?.doesSomethingWhenHeld == true
                                ? L("This key still does its usual job while you hold it. A function key or a right-hand modifier avoids that.")
                                : nil)
                    )
                }
            }

            LabeledContent {
                Text(state.dockEdge.label)
            } label: {
                RowLabel(
                    title: L("Dock position"),
                    caption: L("Set in System Settings → Desktop & Dock. DockPin follows it.")
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
                Button(L("Re-anchor Now")) { model.actions?.reanchorNow() }
                    .disabled(state.reanchorDisabledReason != nil)
            } label: {
                RowLabel(
                    title: L("Re-anchor the Dock"),
                    caption: state.reanchorDisabledReason
                        ?? L("Brings the Dock back to the allowed display by briefly moving the pointer to its edge.")
                )
            }
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.storedProfilesUnreadable ? L("Your saved profiles couldn’t be read") : L("Set up DockPin"))
                    .font(.headline)
                Text(state.storedProfilesUnreadable
                    ? L("DockPin kept a backup copy of the saved data. Start fresh to create a new profile.")
                    : L("Create a profile, choose the displays the Dock is allowed on, then turn on pinning."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(state.storedProfilesUnreadable ? L("Start Fresh") : L("Set Up")) {
                    model.actions?.createFirstProfile()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 6)
        }
    }
}
