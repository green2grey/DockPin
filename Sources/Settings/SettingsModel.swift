import Foundation

/// What the settings window (and the menu) can ask the app to do. `AppDelegate` implements it;
/// the views never touch the engine themselves.
@MainActor
protocol SettingsActions: AnyObject {
    func setPinningEnabled(_ enabled: Bool)
    func setDisplay(_ display: DisplayRow, allowed: Bool)
    func setOverrideModifier(_ modifier: ModifierOption)
    func setCustomOverrideKey(_ key: CustomOverrideKey)
    func reanchorNow()

    func createFirstProfile()
    func selectProfile(_ id: UUID)
    /// Returns the new profile's ID so the window can start renaming it.
    func addProfile() -> UUID?
    func renameProfile(_ id: UUID, to name: String)
    func deleteProfile(_ id: UUID)
    func linkProfileToCurrentDisplays(_ id: UUID)
    func setAutoSwitch(_ enabled: Bool)
    func resumeAutoSwitching()

    func setShowsMenuBarIcon(_ shows: Bool)
    func setLaunchAtLogin(_ enabled: Bool)
    func setAutomaticUpdateChecks(_ enabled: Bool)
    func checkForUpdates()
    func cancelUpdate()
    func installUpdate()
    func skipUpdate()
    func postponeUpdate()
    func installUpdateAndRelaunch()
    func showUpdateDetails()
    func openAccessibilitySettings()
    func openLoginItemsSettings()
    func showHelp()
    func showWhatsNew()
    func openWebsite()
    func openIssueTracker()
}

/// The settings window's view model: a snapshot of app state that `AppDelegate` replaces whenever
/// anything changes, plus the pane on show.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var state = SettingsState()
    @Published var pane: SettingsPane = .displays
    weak var actions: SettingsActions?
}
