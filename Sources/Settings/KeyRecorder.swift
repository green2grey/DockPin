import AppKit

/// Captures the next key the user presses while the settings window is in front.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private var monitor: Any?
    private var onKey: ((CustomOverrideKey) -> Void)?

    /// Starts listening. `onKey` runs once with the key pressed; Escape cancels instead.
    func start(onKey: @escaping (CustomOverrideKey) -> Void) {
        stop()
        self.onKey = onKey
        isRecording = true

        // A local monitor only sees events headed for this app, so nothing is read while the
        // user is typing elsewhere. Returning nil keeps the key press from also acting on the
        // window (typing into a field, triggering a button).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onKey = nil
        isRecording = false
    }

    /// Handles one event while recording. Returns true if the event was used and should go no
    /// further.
    private func consume(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        switch event.type {
        case .keyDown:
            if event.isARepeat { return true }
            if event.keyCode == 53 {
                // Escape backs out, so it can't itself be recorded.
                stop()
                return true
            }
            finish(CustomOverrideKey(
                keyCode: event.keyCode,
                label: KeyNames.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            ))
            return true

        case .flagsChanged:
            // Modifier keys report both press and release here; only a press counts.
            guard let flag = KeyNames.modifierFlag(for: event.keyCode),
                  event.modifierFlags.contains(flag)
            else { return false }
            finish(CustomOverrideKey(keyCode: event.keyCode, label: KeyNames.label(keyCode: event.keyCode)))
            return true

        default:
            return false
        }
    }

    private func finish(_ key: CustomOverrideKey) {
        let callback = onKey
        stop()
        callback?(key)
    }
}
