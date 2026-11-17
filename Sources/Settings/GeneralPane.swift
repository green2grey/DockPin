import SwiftUI

/// App-wide settings: menu bar icon, login item, permission, updates, links.
struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    private var state: SettingsState { model.state }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { Localization.shared.preference },
                    set: { Localization.shared.preference = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    RowLabel(
                        title: L("Language"),
                        caption: L("Automatic follows the language your Mac uses.")
                    )
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { state.showsMenuBarIcon },
                    set: { model.actions?.setShowsMenuBarIcon($0) }
                )) {
                    RowLabel(
                        title: L("Show in menu bar"),
                        caption: state.showsMenuBarIcon
                            ? L("Turn off to keep DockPin out of the menu bar.")
                            : L("Hidden. Open DockPin again from Applications or Spotlight to get back here. The icon returns by itself if DockPin needs your attention.")
                    )
                }

                Toggle(isOn: Binding(
                    get: { state.launchAtLogin != .off },
                    set: { model.actions?.setLaunchAtLogin($0) }
                )) {
                    RowLabel(
                        title: L("Launch at login"),
                        caption: state.launchAtLoginError,
                        captionStyle: .orange
                    )
                }

                if state.launchAtLogin == .needsApproval {
                    LabeledContent {
                        Button(L("Open Login Items…")) { model.actions?.openLoginItemsSettings() }
                    } label: {
                        RowLabel(
                            title: L("Waiting for approval"),
                            caption: L("Allow DockPin under System Settings → General → Login Items.")
                        )
                    }
                }
            }

            Section {
                LabeledContent {
                    if state.isAccessibilityTrusted {
                        Label(L("Granted"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L("Open System Settings…")) { model.actions?.openAccessibilitySettings() }
                    }
                } label: {
                    RowLabel(
                        title: L("Accessibility access"),
                        caption: L("DockPin uses it to stop the pointer from summoning the Dock on other displays.")
                    )
                }
            } header: {
                Text(L("Permissions"))
            }

            Section {
                LabeledContent(L("Version"), value: state.version)
                UpdateStatusRow(model: model)
                Toggle(L("Check for updates automatically"), isOn: Binding(
                    get: { state.automaticallyChecksForUpdates },
                    set: { model.actions?.setAutomaticUpdateChecks($0) }
                ))
            } header: {
                Text(L("Updates"))
            }

            Section {
                linkRow(L("What’s New"), symbol: "sparkles") { model.actions?.showWhatsNew() }
                linkRow(L("DockPin Help"), symbol: "questionmark.circle") { model.actions?.showHelp() }
                linkRow(L("Website"), symbol: "globe") { model.actions?.openWebsite() }
                linkRow(L("Report a Problem"), symbol: "ladybug") { model.actions?.openIssueTracker() }
            }
        }
        .formStyle(.grouped)
    }

    private func linkRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.link)
    }
}

/// The one row that carries a whole update from "check" to "install and relaunch", so nothing
/// about updating ever opens a window of its own.
private struct UpdateStatusRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        switch model.state.updateStatus {
        case .idle:
            LabeledContent {
                Button(L("Check Now")) { model.actions?.checkForUpdates() }
                    .disabled(!model.state.canCheckForUpdates)
            } label: {
                RowLabel(title: L("Check for updates"), caption: lastCheckedCaption)
            }

        case .checking:
            LabeledContent {
                Button(L("Cancel")) { model.actions?.cancelUpdate() }
            } label: {
                busyLabel(L("Checking for updates…"))
            }

        case .upToDate(let message):
            LabeledContent {
                Button(L("Check Again")) { model.actions?.checkForUpdates() }
                    .disabled(!model.state.canCheckForUpdates)
            } label: {
                IconRowLabel(
                    symbolName: "checkmark.circle.fill",
                    symbolStyle: .green,
                    title: L("DockPin is up to date"),
                    caption: message
                )
            }

        case .available(let info):
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    HStack(spacing: 8) {
                        Menu {
                            Button(L("Open Release Page…")) { model.actions?.showUpdateDetails() }
                            Divider()
                            Button(L("Remind Me Later")) { model.actions?.postponeUpdate() }
                            Button(L("Skip This Version")) { model.actions?.skipUpdate() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 15))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(L("More update options"))

                        Button(info.isInformationOnly ? L("Learn More…") : L("Install Update")) {
                            model.actions?.installUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } label: {
                    IconRowLabel(
                        symbolName: "arrow.down.circle.fill",
                        symbolStyle: .accentColor,
                        title: L("DockPin %@ is available", info.version),
                        caption: info.isCritical ? L("This is an important update.") : nil
                    )
                }

                if !info.notes.isEmpty {
                    ReleaseNotesList(items: info.notes)
                }
            }

        case .downloading(let fraction):
            LabeledContent {
                Button(L("Cancel")) { model.actions?.cancelUpdate() }
            } label: {
                progressLabel(
                    fraction.map { L("Downloading update… %@%%", String(Int(($0 * 100).rounded()))) } ?? L("Downloading update…"),
                    fraction: fraction
                )
            }

        case .preparing(let fraction):
            progressLabel(L("Preparing update…"), fraction: fraction)

        case .readyToInstall:
            LabeledContent {
                HStack(spacing: 8) {
                    Button(L("Later")) { model.actions?.postponeUpdate() }
                    Button(L("Install and Relaunch")) { model.actions?.installUpdateAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                }
            } label: {
                IconRowLabel(
                    symbolName: "arrow.down.circle.fill",
                    symbolStyle: .accentColor,
                    title: L("Update ready to install"),
                    caption: L("DockPin will quit and reopen. Choosing Later installs it when you quit.")
                )
            }

        case .installing:
            busyLabel(L("Installing update…"))

        case .failed(let message):
            LabeledContent {
                Button(L("Try Again")) { model.actions?.checkForUpdates() }
                    .disabled(!model.state.canCheckForUpdates)
            } label: {
                IconRowLabel(
                    symbolName: "exclamationmark.triangle.fill",
                    symbolStyle: .yellow,
                    title: L("Couldn’t update"),
                    caption: message
                )
            }

        case .unavailable(let message):
            IconRowLabel(
                symbolName: "exclamationmark.triangle.fill",
                symbolStyle: .yellow,
                title: L("Updates aren’t available"),
                caption: message
            )
        }
    }

    private var lastCheckedCaption: String {
        guard let date = model.state.lastUpdateCheck else { return L("Not checked yet.") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Localization.shared.locale
        return L("Last checked %@.", formatter.localizedString(for: date, relativeTo: Date()))
    }

    private func busyLabel(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26)
            Text(text)
        }
        .padding(.vertical, 3)
    }

    private func progressLabel(_ text: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 3)
    }
}

/// What's new in an update, listed under the offer to install it. A long list scrolls inside a
/// fixed height so the Install button stays in view.
private struct ReleaseNotesList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("What’s new"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(maxHeight: items.count > 6 ? 150 : nil)
        }
        .padding(.leading, 36)
        .padding(.bottom, 2)
    }
}
