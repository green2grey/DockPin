import AppKit

/// The text of the Help window.
enum HelpContent {
    @MainActor
    static func attributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bodyColor = NSColor.labelColor

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.paragraphSpacing = 8

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacingBefore = 16
        headingParagraph.paragraphSpacing = 6

        func title(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: titleFont,
                .foregroundColor: bodyColor,
            ]))
        }

        func heading(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: headingFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: headingParagraph,
            ]))
        }

        func body(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyParagraph,
            ]))
        }

        func bullet(_ text: String) {
            body("• " + text)
        }

        func numbered(_ number: Int, _ text: String) {
            body("\(number). " + text)
        }

        title("DockPin")
        body(L("Keep your Dock exactly where you want it."))

        heading(L("Getting Started"))
        numbered(1, L("Grant Accessibility permission when prompted (System Settings → Privacy & Security → Accessibility). DockPin notices within a couple of seconds; no relaunch needed. The menu bar icon shows a warning triangle while access is missing."))
        numbered(2, L("Click DockPin in the menu bar and choose DockPin Settings…."))
        numbered(3, L("Under Displays, switch on the displays the Dock is allowed on."))
        numbered(4, L("Turn on Pin the Dock."))

        heading(L("The Menu"))
        body(L("The menu bar icon is a filled pin while the Dock is being held in place. Its menu shows what DockPin is doing and has the everyday actions: Pin the Dock, Re-anchor Dock Now, and a profile switcher once you have more than one profile. Everything else is in Settings."))

        heading(L("Profiles"))
        body(L("A profile stores:"))
        bullet(L("Which displays can host the Dock"))
        bullet(L("Your override key"))
        bullet(L("Whether pinning is on"))
        body(L("Add, rename and delete profiles under Settings → Profiles. Switch between them from the menu or from the pill at the top right of Settings. Choosing a profile by hand pauses auto-switching until you choose Resume."))

        heading(L("Auto-switching"))
        body(L("Each profile remembers which external displays were connected when you created it. With auto-switching on, DockPin switches to the profile whose displays are all connected whenever your displays change. If several profiles fit, the one that matches more displays wins; if it’s still a tie, DockPin doesn’t switch."))
        body(L("Profiles made before version 2.2 pick up their displays the first time you select them by hand. To change which displays a profile belongs to, use Link to Current Displays in its options."))

        heading(L("Dock Position"))
        body(L("DockPin follows the Dock position set in macOS (Left, Bottom, or Right). If another display fully covers the chosen edge of a display, macOS won’t place the Dock there, and DockPin says so next to that display."))

        heading(L("Re-anchor Dock Now"))
        body(L("macOS does not provide any way for apps to move the Dock to a specific display. Re-anchor briefly moves the pointer to the allowed display’s edge and back, which is the gesture macOS uses to relocate the Dock. This is best-effort — it may not work in every situation."))
        body(L("Re-anchor is available when exactly one connected display is allowed and its Dock edge is free. DockPin also checks on its own when it starts, when you turn pinning on or switch profiles, when displays change, and after your Mac wakes or unlocks. Those automatic checks only take the pointer if the Dock is actually on the wrong display, and they wait while you’re holding a mouse button."))
        body(L("If you move the Dock yourself while holding the override key, DockPin leaves it there until your displays change or your Mac next wakes or unlocks."))

        heading(L("Override Key"))
        body(L("Hold a modifier key (Option by default) to bypass pinning for a moment and move the Dock freely. You can change the key per profile under Settings → Displays."))
        body(L("Choose Custom… to use any key: click Record…, then press it. A function key such as F13 or a right-hand modifier works best, because an ordinary key still types while you hold it."))

        heading(L("Hiding the Menu Bar Icon"))
        body(L("Turn off Show in menu bar under Settings → General. To get back to Settings, open DockPin again from Applications or Spotlight. The icon returns on its own while DockPin needs your attention, for example if Accessibility access is lost."))

        heading(L("Updates"))
        body(L("DockPin checks for updates on its own unless you turn that off under Settings → General. When one is found, the menu shows Update Available… and the Updates section there offers to install it; checking, downloading and installing all happen in that section, along with a list of what’s new. After an update, DockPin shows What’s New once; it stays available under Settings → General."))

        heading(L("Launch at Login"))
        body(L("Turn on Launch at login under Settings → General so DockPin starts when you log in."))

        heading(L("Requirements"))
        bullet(L("macOS 13 or later"))
        bullet(L("Two or more connected displays"))
        bullet(L("Dock positioned on the Left, Bottom, or Right edge"))
        bullet(L("“Displays have separate Spaces” enabled (System Settings → Desktop & Dock)"))

        return result
    }
}
