import SwiftUI

/// The list of profiles and how DockPin switches between them.
struct ProfilesPane: View {
    @ObservedObject var model: SettingsModel

    @State private var renamingID: UUID?
    @State private var draftName = ""
    @State private var pendingDelete: ProfileRow?
    @FocusState private var nameFieldFocused: Bool

    private var state: SettingsState { model.state }

    var body: some View {
        Form {
            Section {
                ForEach(state.profiles) { profile in
                    row(for: profile)
                }
                Button {
                    if let id = model.actions?.addProfile() {
                        beginRenaming(id: id, currentName: model.state.profiles.first { $0.id == id }?.name ?? "")
                    }
                } label: {
                    Label("New Profile", systemImage: "plus")
                        .foregroundStyle(state.hasProfile ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!state.hasProfile)
            } header: {
                Text("Profiles")
            } footer: {
                SectionFootnote("A new profile starts as a copy of the one in use, linked to the displays connected right now.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { state.autoSwitchEnabled },
                    set: { model.actions?.setAutoSwitch($0) }
                )) {
                    RowLabel(
                        title: "Switch profiles automatically",
                        caption: "When your displays change, DockPin switches to the profile linked to the ones that are connected."
                    )
                }

                if state.autoSwitchPaused {
                    LabeledContent {
                        Button("Resume") { model.actions?.resumeAutoSwitching() }
                    } label: {
                        RowLabel(
                            title: "Paused",
                            caption: "You chose a profile by hand, so DockPin is leaving it alone."
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) { model.actions?.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    @ViewBuilder
    private func row(for profile: ProfileRow) -> some View {
        HStack(spacing: 10) {
            Button {
                model.actions?.selectProfile(profile.id)
            } label: {
                Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(profile.isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(profile.isActive ? "In use" : "Use this profile")
            .accessibilityLabel(profile.isActive ? "\(profile.name), in use" : "Use \(profile.name)")

            VStack(alignment: .leading, spacing: 2) {
                if renamingID == profile.id {
                    TextField("Profile name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($nameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { renamingID = nil }
                } else {
                    Text(profile.name)
                }
                Text(profile.triggerSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if renamingID == profile.id {
                Button("Done") { commitRename() }
            } else {
                Menu {
                    Button("Rename…") { beginRenaming(id: profile.id, currentName: profile.name) }
                    Button("Link to Current Displays") { model.actions?.linkProfileToCurrentDisplays(profile.id) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = profile }
                        .disabled(state.profiles.count < 2)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(profile.name)")
            }
        }
    }

    private func beginRenaming(id: UUID, currentName: String) {
        draftName = currentName
        renamingID = id
        nameFieldFocused = true
    }

    private func commitRename() {
        if let id = renamingID {
            model.actions?.renameProfile(id, to: draftName)
        }
        renamingID = nil
    }
}
