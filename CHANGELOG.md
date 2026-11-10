# Changelog

What's new in each version of DockPin. The entry for a release is shown to people when they're
offered that update, and in the app under Settings → General → What's New.

Keep each item on one line and in plain words: the build script turns the entry for the version
being released into the update feed's release notes.

## 2.2

### New
- A Settings window. The menu is now short (pin, re-anchor, switch profile) and everything else lives in Settings, under Displays, Profiles and General.
- Hide the menu bar icon. Turn off "Show in menu bar" under Settings → General; open DockPin again from Applications or Spotlight to get back.
- Custom override key. Record any key, not only a modifier, to let the Dock move freely while you hold it.
- Rename and delete profiles, and choose which displays a profile belongs to.
- Updates are checked, downloaded and installed inside Settings, with a list of what's new.
- No setup wizard. DockPin starts with a profile for the display your Dock is on; just turn on Pin the Dock.

### Improved
- The menu bar icon shows what DockPin is doing: a filled pin only while the Dock is being held, and a warning when Accessibility access is missing.
- Granting Accessibility access takes effect within a couple of seconds, with no relaunch.
- The Dock is checked and put back after your Mac starts, wakes or unlocks.
- DockPin moves the pointer to re-anchor only when the Dock is on the wrong display, and waits while you're holding a mouse button.
- If you move the Dock yourself with the override key, DockPin leaves it there.
- DockPin stops cleanly if Accessibility access is removed while it's running.
- Launch at login reports problems instead of failing silently.

### Fixed
- Re-anchor Dock Now works again on current versions of macOS.
- Auto-switch Profiles now switches. Profiles from earlier versions learn their displays the first time you select them.
- The pointer could be left at the Dock edge when displays changed quickly.
- Saved profiles could be lost if DockPin couldn't read them.
- DockPin no longer tries to pin when "Displays have separate Spaces" is turned off.
- Copy and paste now work in DockPin's text fields.

## 2.1

- Left, bottom and right Dock positions. DockPin follows the Dock position set in macOS instead of assuming the bottom.
- Layout warnings when your display arrangement blocks the Dock edge on a display you chose, such as one monitor stacked above another.
- Re-anchor Dock Now, a best-effort way to pull the Dock back to the allowed display.
- DockPin refuses to turn on when no allowed display has a free Dock edge, and says why.
- A change of Dock position in System Settings is picked up within half a second.

## 2.0

- Display profiles: save and switch Dock settings for each display setup.
- Auto-switch profiles when your connected displays change.
- A guided setup for first-time configuration.
- Automatic updates.
- A configurable modifier key to override pinning.
- A lightweight menu bar app with no Dock icon.
