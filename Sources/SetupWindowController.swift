import AppKit

final class SetupWindowController: NSWindowController, NSTextFieldDelegate {
    var onFinish: ((String, Set<DisplayStableID>, ModifierOption, Bool) -> Void)?

    private let nameField = NSTextField(string: "")
    private let displaysStack = NSStackView()
    private let serialLessNoteRow = NSStackView()
    private let dockEdgeLabel = NSTextField(wrappingLabelWithString: "")
    private let layoutWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let modifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enableAfterSetupCheckbox = NSButton(checkboxWithTitle: "Enable DockPin after setup", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish", target: nil, action: nil)

    private var displayCheckboxes: [(button: NSButton, descriptor: DisplayDescriptor)] = []
    private var currentSnapshot = DisplaySnapshot(displays: [])
    private var currentDockEdge: DockEdge = .bottom

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up DockPin"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        super.init(window: panel)

        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(snapshot: DisplaySnapshot) {
        currentSnapshot = snapshot
        currentDockEdge = DockEdge.current()
        refreshDisplays(snapshot: snapshot)
        updateDockEdgeCopy()
        updateFinishEnabled()

        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(nameField)
    }

    private func setupUI() {
        guard let panel = window as? NSPanel else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        panel.contentView = contentView
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        root.addArrangedSubview(sectionLabel("Profile Name"))
        nameField.placeholderString = "My Profile"
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(controlDidChange)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        root.addArrangedSubview(nameField)

        root.addArrangedSubview(sectionLabel("Allow Dock on These Displays"))
        displaysStack.orientation = .vertical
        displaysStack.alignment = .leading
        displaysStack.spacing = 8
        root.addArrangedSubview(displaysStack)

        serialLessNoteRow.orientation = .horizontal
        serialLessNoteRow.alignment = .centerY
        serialLessNoteRow.spacing = 8
        serialLessNoteRow.isHidden = true

        let infoImage = NSImageView()
        infoImage.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        infoImage.contentTintColor = .secondaryLabelColor
        infoImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        let noteLabel = NSTextField(wrappingLabelWithString: "Some displays can’t be uniquely identified; identical models may be treated as a group.")
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor

        serialLessNoteRow.addArrangedSubview(infoImage)
        serialLessNoteRow.addArrangedSubview(noteLabel)
        root.addArrangedSubview(serialLessNoteRow)

        dockEdgeLabel.font = .systemFont(ofSize: 12)
        dockEdgeLabel.textColor = .secondaryLabelColor
        dockEdgeLabel.maximumNumberOfLines = 0
        root.addArrangedSubview(dockEdgeLabel)

        layoutWarningLabel.font = .systemFont(ofSize: 12)
        layoutWarningLabel.textColor = .systemOrange
        layoutWarningLabel.maximumNumberOfLines = 0
        layoutWarningLabel.isHidden = true
        root.addArrangedSubview(layoutWarningLabel)

        root.addArrangedSubview(sectionLabel("Override Modifier Key"))
        for opt in ModifierOption.allCases {
            modifierPopup.addItem(withTitle: opt.label)
            modifierPopup.lastItem?.tag = opt.rawValue
        }
        modifierPopup.selectItem(withTag: ModifierOption.option.rawValue)
        root.addArrangedSubview(modifierPopup)

        enableAfterSetupCheckbox.state = .off
        root.addArrangedSubview(enableAfterSetupCheckbox)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"

        finishButton.bezelStyle = .rounded
        finishButton.target = self
        finishButton.action = #selector(finishPressed)
        finishButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(finishButton)
        root.addArrangedSubview(buttons)

        finishButton.isEnabled = false
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func refreshDisplays(snapshot: DisplaySnapshot) {
        for entry in displayCheckboxes {
            displaysStack.removeArrangedSubview(entry.button)
            entry.button.removeFromSuperview()
        }
        displayCheckboxes = []

        for d in snapshot.displays {
            let cb = NSButton(checkboxWithTitle: d.localizedName, target: self, action: #selector(controlDidChange))
            cb.state = .off
            displayCheckboxes.append((button: cb, descriptor: d))
            displaysStack.addArrangedSubview(cb)
        }

        updateSerialLessNoteVisibility()
        updateLayoutWarning()
    }

    private func selectedDisplays() -> [DisplayDescriptor] {
        displayCheckboxes.compactMap { entry in
            guard entry.button.state == .on else { return nil }
            return entry.descriptor
        }
    }

    private func updateSerialLessNoteVisibility() {
        serialLessNoteRow.isHidden = !selectedDisplays().contains(where: { !$0.stableID.hasSerial })
    }

    private func updateFinishEnabled() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finishButton.isEnabled = !name.isEmpty && !selectedDisplays().isEmpty
    }

    private func updateDockEdgeCopy() {
        dockEdgeLabel.stringValue =
            "Current macOS Dock edge: \(currentDockEdge.label). DockPin can only keep the Dock on displays with an exposed \(currentDockEdge.requirementDescription)."
    }

    private func currentReachabilityMap() -> [CGDirectDisplayID: DisplayEdgeReachability] {
        DisplayLayoutAnalyzer.reachabilityMap(snapshot: currentSnapshot, edge: currentDockEdge)
    }

    private func updateLayoutWarning() {
        let reachability = currentReachabilityMap()
        let blocked = selectedDisplays()
            .filter { descriptor in
                guard let info = reachability[descriptor.displayID] else { return false }
                return !info.isReachable
            }
            .map(\.localizedName)

        guard !blocked.isEmpty else {
            layoutWarningLabel.isHidden = true
            layoutWarningLabel.stringValue = ""
            return
        }

        let names = blocked.joined(separator: ", ")
        layoutWarningLabel.stringValue =
            "\(currentDockEdge.label) edge is blocked on \(names). Rearrange displays or switch macOS Dock position to a different edge before enabling DockPin for that display."
        layoutWarningLabel.isHidden = false
    }

    private func hasReachableSelectedDisplay() -> Bool {
        let reachability = currentReachabilityMap()
        return selectedDisplays().contains { descriptor in
            reachability[descriptor.displayID]?.isReachable == true
        }
    }

    private func showBlockedEnableAlert() {
        let reachability = currentReachabilityMap()
        let blocked = selectedDisplays()
            .filter { descriptor in
                reachability[descriptor.displayID]?.isReachable == false
            }
            .map(\.localizedName)
        let summary = blocked.prefix(3).joined(separator: ", ")
        let suffix = blocked.count > 3 ? ", +\(blocked.count - 3) more" : ""

        let alert = NSAlert()
        alert.messageText = "Enable after setup needs an exposed \(currentDockEdge.requirementDescription)."
        alert.informativeText =
            "Either uncheck \"Enable DockPin after setup\", rearrange your displays, or change the macOS Dock position before continuing. Blocked: \(summary)\(suffix)."
        alert.alertStyle = .informational
        alert.runModal()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateFinishEnabled()
    }

    @objc private func controlDidChange() {
        updateSerialLessNoteVisibility()
        updateLayoutWarning()
        updateFinishEnabled()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    @objc private func finishPressed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedDisplays()
        guard !name.isEmpty, !selected.isEmpty else { return }
        if enableAfterSetupCheckbox.state == .on, !hasReachableSelectedDisplay() {
            showBlockedEnableAlert()
            return
        }

        let allowed = Set(selected.map(\.stableID))
        let opt = ModifierOption(rawValue: modifierPopup.selectedTag()) ?? .option
        let enableAfterSetup = enableAfterSetupCheckbox.state == .on

        onFinish?(name, allowed, opt, enableAfterSetup)
        window?.close()
    }
}
