import AppKit
import SwiftUI

/// The settings window's content: a sidebar of panes on the left, the chosen pane on the right
/// under a header that carries the profile switcher.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    static let size = CGSize(width: 780, height: 580)
    static let sidebarWidth: CGFloat = 210
    /// Room for the window's close/minimise buttons, which sit over the sidebar.
    static let titleBarInset: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pane: $model.pane)
                .frame(width: Self.sidebarWidth)

            VStack(spacing: 0) {
                SettingsHeader(model: model)
                Group {
                    switch model.pane {
                    case .displays: DisplaysPane(model: model)
                    case .profiles: ProfilesPane(model: model)
                    case .general: GeneralPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // Fixed width; the height follows the window, whose content view includes the title bar.
        .frame(minWidth: Self.size.width, maxWidth: Self.size.width,
               minHeight: Self.size.height, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                SidebarItem(item: item, isSelected: item == pane) { pane = item }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, SettingsView.titleBarInset)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }
}

private struct SidebarItem: View {
    let item: SettingsPane
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The translucent material macOS uses behind sidebars.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Header

private struct SettingsHeader: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Text("DockPin")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            if model.state.hasProfile {
                ProfileSwitcher(model: model)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: SettingsView.titleBarInset)
    }
}

/// The pill at the top right: shows the profile in use and switches between profiles.
private struct ProfileSwitcher: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Menu {
            ForEach(model.state.profiles) { profile in
                Button {
                    model.actions?.selectProfile(profile.id)
                } label: {
                    if profile.isActive {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Manage Profiles…") { model.pane = .profiles }
        } label: {
            Text(model.state.activeProfileName)
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .help("The profile in use")
        .accessibilityLabel("Profile: \(model.state.activeProfileName)")
    }
}

// MARK: - Shared pieces

/// A row label with a symbol in a fixed-width column, so stacked rows line up.
struct IconRowLabel: View {
    let symbolName: String
    var symbolStyle: Color = .primary
    let title: String
    var caption: String?
    var captionStyle: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16))
                .foregroundStyle(symbolStyle)
                .frame(width: 26)
            RowLabel(title: title, caption: caption, captionStyle: captionStyle)
        }
        .padding(.vertical, 3)
    }
}

/// The note under a group of settings.
struct SectionFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A settings row label: a title with an optional line of explanation under it.
struct RowLabel: View {
    let title: String
    var caption: String?
    var captionStyle: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(captionStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
