import AppKit

/// Shows read-only pages of text (Help, What's New), each in its own small window that is
/// created on first use and brought back to the front after that.
@MainActor
final class TextWindows {
    private struct Page {
        let window: NSWindow
        let title: () -> String
        let content: () -> NSAttributedString
    }

    private var pages: [String: Page] = [:]

    func show(id: String, title: @autoclosure @escaping () -> String,
              content: @autoclosure @escaping () -> NSAttributedString) {
        if let page = pages[id] {
            // The text may have changed since the window was made (a newer changelog after an
            // update), and so may the language it is written in.
            page.window.title = title()
            setText(page.content(), in: page.window)
            page.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title()
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

        pages[id] = Page(window: window, title: { title() }, content: { content() })
    }

    /// Rebuilds every open page, for when the interface language changes underneath it.
    func refresh() {
        for page in pages.values {
            page.window.title = page.title()
            setText(page.content(), in: page.window)
        }
    }

    private func setText(_ content: NSAttributedString, in window: NSWindow) {
        (window.contentView as? NSScrollView)
            .flatMap { $0.documentView as? NSTextView }?
            .textStorage?.setAttributedString(content)
    }
}
