import AppKit

/// Shows read-only pages of text (Help, What's New), each in its own small window that is
/// created on first use and brought back to the front after that.
@MainActor
final class TextWindows {
    private var windows: [String: NSWindow] = [:]

    func show(id: String, title: String, content: @autoclosure () -> NSAttributedString) {
        if let window = windows[id] {
            // The text may have changed since the window was made (a newer changelog after an update).
            (window.contentView as? NSScrollView)
                .flatMap { $0.documentView as? NSTextView }?
                .textStorage?.setAttributedString(content())
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let text = NSTextView(frame: scroll.contentView.bounds)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 24, height: 24)
        text.drawsBackground = false
        text.textContainer?.lineFragmentPadding = 0
        text.textStorage?.setAttributedString(content())

        scroll.documentView = text
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[id] = window
    }
}
