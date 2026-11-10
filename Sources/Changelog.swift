import AppKit

/// One release's entry in CHANGELOG.md.
struct ChangelogEntry: Equatable, Identifiable, Sendable {
    struct Section: Equatable, Sendable {
        /// "New", "Fixed" and so on; nil for items listed straight under the version.
        var title: String?
        var items: [String]
    }

    var version: String
    var sections: [Section]

    var id: String { version }

    var items: [String] {
        sections.flatMap(\.items)
    }
}

/// Reads the changelog that ships inside the app (CHANGELOG.md, copied in by the build scripts).
enum Changelog {
    static func bundled() -> [ChangelogEntry] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    /// Understands the small part of Markdown the changelog uses: `## version`, `### section`,
    /// and `- item` lines. Anything else (the introduction, blank lines) is ignored.
    static func parse(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var current: ChangelogEntry?
        var section: ChangelogEntry.Section?

        func closeSection() {
            if let finished = section, !finished.items.isEmpty {
                current?.sections.append(finished)
            }
            section = nil
        }

        func closeEntry() {
            closeSection()
            if let finished = current, !finished.sections.isEmpty {
                entries.append(finished)
            }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                closeEntry()
                // "## 2.2" or "## 2.2 - 2026-11-20": the version is the first word.
                let version = line.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                if !version.isEmpty {
                    current = ChangelogEntry(version: version, sections: [])
                }
            } else if line.hasPrefix("### ") {
                guard current != nil else { continue }
                closeSection()
                section = ChangelogEntry.Section(title: String(line.dropFirst(4)), items: [])
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                guard current != nil else { continue }
                if section == nil {
                    section = ChangelogEntry.Section(title: nil, items: [])
                }
                section?.items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        closeEntry()
        return entries
    }

    /// The whole changelog laid out for the What's New window, newest version first.
    @MainActor
    static func attributedString(for entries: [ChangelogEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let color = NSColor.labelColor

        let versionParagraph = NSMutableParagraphStyle()
        versionParagraph.paragraphSpacingBefore = 18
        versionParagraph.paragraphSpacing = 6

        let sectionParagraph = NSMutableParagraphStyle()
        sectionParagraph.paragraphSpacingBefore = 8
        sectionParagraph.paragraphSpacing = 4

        let itemParagraph = NSMutableParagraphStyle()
        itemParagraph.paragraphSpacing = 5
        itemParagraph.headIndent = 14
        itemParagraph.firstLineHeadIndent = 0
        itemParagraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]

        for (index, entry) in entries.enumerated() {
            let heading = NSMutableParagraphStyle()
            heading.setParagraphStyle(versionParagraph)
            if index == 0 { heading.paragraphSpacingBefore = 0 }
            result.append(NSAttributedString(string: "Version \(entry.version)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: color,
                .paragraphStyle: heading,
            ]))

            for section in entry.sections {
                if let title = section.title {
                    result.append(NSAttributedString(string: title + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: sectionParagraph,
                    ]))
                }
                for item in section.items {
                    result.append(NSAttributedString(string: "•\t\(item)\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: color,
                        .paragraphStyle: itemParagraph,
                    ]))
                }
            }
        }
        return result
    }
}

/// Pulls the list of changes out of the release notes that come with an update.
enum ReleaseNotes {
    /// The bullet points in a piece of release-notes HTML. DockPin's own feed writes each change
    /// as a list item; for anything else, every non-empty line of text counts as one.
    static func items(fromHTML html: String) -> [String] {
        // Styles and scripts are not content.
        let content = replacing(#"<(style|script)\b[^>]*>.*?</\1>"#, in: html, with: " ")

        let listItems = matches(of: #"<li\b[^>]*>(.*?)</li>"#, in: content).map(plainText)
            .filter { !$0.isEmpty }
        if !listItems.isEmpty { return listItems }

        return replacing(#"<(br|/p|/div|/h[1-6])\b[^>]*>"#, in: content, with: "\n")
            .components(separatedBy: .newlines)
            .map(plainText)
            .filter { !$0.isEmpty }
    }

    /// Release notes written as plain text: one item per line, without list markers.
    static func items(fromPlainText text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                    line = String(line.dropFirst(marker.count))
                }
                return line
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func plainText(_ fragment: String) -> String {
        var text = replacing(#"<[^>]+>"#, in: fragment, with: "")
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&rarr;", "→"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement
        )
    }

    /// The first capture group of every match.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

/// Decides whether to show What's New when DockPin starts.
enum UpgradeNotice {
    /// - Parameters:
    ///   - previousVersion: the version that last ran here, if this copy has recorded one.
    ///   - hadEarlierInstall: there are signs of a version from before DockPin kept that record
    ///     (saved profiles, an earlier update check).
    static func shouldShow(previousVersion: String?, currentVersion: String, hadEarlierInstall: Bool) -> Bool {
        if let previousVersion {
            return previousVersion != currentVersion
        }
        // No record: either a brand-new install, which gets no "what's new", or the first run
        // after updating from a version that didn't keep one.
        return hadEarlierInstall
    }
}
