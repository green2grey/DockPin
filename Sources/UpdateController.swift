import AppKit
import Sparkle

/// A found update, reduced to what the interface shows.
struct UpdateInfo: Equatable, Sendable {
    var version: String
    /// Nothing to download; the feed only points at a page to read.
    var isInformationOnly = false
    var isCritical = false
    /// Where to read about it: release notes if the feed has them, otherwise the item's own page.
    var detailsURL: URL?
    /// What's new in it, one change per entry, when the feed says.
    var notes: [String] = []
}

/// Where an update check or installation stands. This is what the Updates section shows.
enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    /// A check found nothing newer. Carries Sparkle's wording of why.
    case upToDate(String)
    case available(UpdateInfo)
    /// `fraction` is nil until the size of the download is known.
    case downloading(fraction: Double?)
    case preparing(fraction: Double)
    case readyToInstall
    case installing
    case failed(String)
    /// The updater itself could not start.
    case unavailable(String)

    /// The user has a choice to make before anything else happens.
    var awaitsDecision: Bool {
        switch self {
        case .available, .readyToInstall: return true
        default: return false
        }
    }
}

enum UpdateChoice: Sendable {
    case install
    case skip
    case later
}

enum UpdateStage: Sendable {
    case notDownloaded
    case downloaded
    /// Downloaded and unpacked earlier; only the install itself is left.
    case installing
}

/// Runs update checks and installs through Sparkle, with DockPin's own settings window as the
/// interface in place of Sparkle's alert windows.
///
/// The methods in the first half are the whole state machine and deal only in plain values, so
/// they can be tested without Sparkle. The `SPUUserDriver` conformance at the bottom translates
/// Sparkle's callbacks into them.
@MainActor
final class UpdateController: NSObject {
    private(set) var status: UpdateStatus = .idle {
        didSet { if status != oldValue { onChange?() } }
    }
    /// An update turned up in a background check and is waiting for the user, who hasn't asked
    /// about updates and may not have Settings open.
    private(set) var hasUnrequestedUpdate = false {
        didSet { if hasUnrequestedUpdate != oldValue { onChange?() } }
    }

    var onChange: (() -> Void)?
    /// Sparkle wants the update interface in front of the user.
    var onShowInFocus: (() -> Void)?

    private var updater: SPUUpdater?
    private var cancelAction: (() -> Void)?
    private var foundReply: ((UpdateChoice) -> Void)?
    private var installReply: ((UpdateChoice) -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    // MARK: - Updater

    func start() {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    // MARK: - What the user can do

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    /// Cancels a check or a download in progress.
    func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }

    /// Starts installing the update on offer.
    func install() {
        guard case .available(let info) = status, let reply = foundReply else { return }
        foundReply = nil
        hasUnrequestedUpdate = false
        if info.isInformationOnly {
            // Nothing to install; the caller sends the user to the update's page.
            status = .idle
            reply(.later)
            return
        }
        status = .downloading(fraction: nil)
        reply(.install)
    }

    func skip() {
        guard let reply = foundReply else { return }
        foundReply = nil
        hasUnrequestedUpdate = false
        status = .idle
        reply(.skip)
    }

    /// Puts the decision off. An update that was already prepared installs when DockPin quits.
    func later() {
        let reply = foundReply ?? installReply
        foundReply = nil
        installReply = nil
        hasUnrequestedUpdate = false
        guard let reply else { return }
        status = .idle
        reply(.later)
    }

    func installAndRelaunch() {
        guard let reply = installReply else { return }
        installReply = nil
        hasUnrequestedUpdate = false
        status = .installing
        reply(.install)
    }

    // MARK: - What the updater reports

    func checkStarted(cancel: @escaping () -> Void) {
        cancelAction = cancel
        status = .checking
    }

    func updateFound(
        _ info: UpdateInfo,
        stage: UpdateStage,
        userInitiated: Bool,
        reply: @escaping (UpdateChoice) -> Void
    ) {
        cancelAction = nil
        if stage == .installing {
            foundReply = nil
            installReply = reply
            status = .readyToInstall
        } else {
            installReply = nil
            foundReply = reply
            status = .available(info)
        }
        hasUnrequestedUpdate = !userInitiated
    }

    /// Release notes that the feed links to, rather than embeds, arrive after the update is found.
    func releaseNotesArrived(_ items: [String]) {
        guard case .available(var info) = status, info.notes.isEmpty, !items.isEmpty else { return }
        info.notes = items
        status = .available(info)
    }

    func noUpdateFound(message: String) {
        cancelAction = nil
        status = .upToDate(message)
    }

    func failed(message: String) {
        clearPendingReplies()
        status = .failed(message)
    }

    func downloadStarted(cancel: @escaping () -> Void) {
        cancelAction = cancel
        expectedLength = 0
        receivedLength = 0
        status = .downloading(fraction: nil)
    }

    func downloadExpects(length: UInt64) {
        expectedLength = length
        publishDownloadProgress()
    }

    func downloadReceived(length: UInt64) {
        receivedLength += length
        publishDownloadProgress()
    }

    private func publishDownloadProgress() {
        guard expectedLength > 0 else {
            status = .downloading(fraction: nil)
            return
        }
        // Whole percents only: data arrives in many small pieces, and each change redraws.
        let fraction = min(1, Double(receivedLength) / Double(expectedLength))
        status = .downloading(fraction: (fraction * 100).rounded(.down) / 100)
    }

    func extractionStarted() {
        cancelAction = nil
        status = .preparing(fraction: 0)
    }

    func extractionProgressed(to progress: Double) {
        status = .preparing(fraction: (min(1, max(0, progress)) * 100).rounded(.down) / 100)
    }

    func readyToInstall(reply: @escaping (UpdateChoice) -> Void) {
        cancelAction = nil
        foundReply = nil
        installReply = reply
        status = .readyToInstall
    }

    func installationStarted() {
        status = .installing
    }

    /// The updater is done with this round, however it went. A result the user should still
    /// read ("up to date", an error) stays on show; anything mid-flight is cleared.
    func sessionEnded() {
        clearPendingReplies()
        switch status {
        case .upToDate, .failed, .unavailable:
            break
        default:
            status = .idle
        }
    }

    private func clearPendingReplies() {
        cancelAction = nil
        foundReply = nil
        installReply = nil
        hasUnrequestedUpdate = false
    }
}

// MARK: - Sparkle

extension UpdateInfo {
    init(_ item: SUAppcastItem) {
        self.init(
            version: item.displayVersionString,
            isInformationOnly: item.isInformationOnlyUpdate,
            isCritical: item.isCriticalUpdate,
            detailsURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL,
            notes: item.itemDescription.map { description in
                item.itemDescriptionFormat == "plain-text"
                    ? ReleaseNotes.items(fromPlainText: description)
                    : ReleaseNotes.items(fromHTML: description)
            } ?? []
        )
    }
}

private extension UpdateChoice {
    var sparkleChoice: SPUUserUpdateChoice {
        switch self {
        case .install: return .install
        case .skip: return .skip
        case .later: return .dismiss
        }
    }
}

private extension UpdateStage {
    init(_ stage: SPUUserUpdateStage) {
        switch stage {
        case .downloaded: self = .downloaded
        case .installing: self = .installing
        default: self = .notDownloaded
        }
    }
}

extension UpdateController: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking automatically is DockPin's default and can be turned off in Settings; no
        // system profile is ever sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkStarted(cancel: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        updateFound(
            UpdateInfo(appcastItem),
            stage: UpdateStage(state.stage),
            userInitiated: state.userInitiated
        ) { choice in
            reply(choice.sparkleChoice)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard let text = String(data: downloadData.data, encoding: .utf8) else { return }
        let isPlainText = downloadData.mimeType?.lowercased().hasPrefix("text/plain") == true
        releaseNotesArrived(isPlainText ? ReleaseNotes.items(fromPlainText: text) : ReleaseNotes.items(fromHTML: text))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let details = error as NSError
        noUpdateFound(message: details.localizedRecoverySuggestion ?? details.localizedDescription)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failed(message: error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadStarted(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        downloadExpects(length: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadReceived(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        extractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        extractionProgressed(to: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyToInstall { choice in
            reply(choice.sparkleChoice)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        installationStarted()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        sessionEnded()
        acknowledgement()
    }

    func showUpdateInFocus() {
        onShowInFocus?()
    }

    func dismissUpdateInstallation() {
        sessionEnded()
    }
}
