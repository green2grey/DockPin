# DockPin - Agent Instructions

DockPin is a native macOS menu bar utility (Swift/AppKit) that pins the Dock to specific displays in multi-monitor setups.

## Project structure

- `Package.swift` — Swift Package Manager manifest (swift-tools-version 5.9, macOS 13+)
- `Sources/` — all Swift source files (single executable target)
- `build.sh` — release build script (requires Apple Developer ID for signing/notarization)
- `Info.plist`, `DockPin.icns` — app bundle resources
- Dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) ≥ 2.9.0 (auto-update framework)
- No test target exists in the package.

## Cursor Cloud specific instructions

### Platform limitation

This is a **macOS-only** application. It imports `Cocoa`, `AppKit`, `CoreGraphics`, and `ApplicationServices` — none of which exist on Linux. Therefore:

- `swift build` **will fail** on the Cloud Agent Linux VM with `error: no such module 'Cocoa'`. This is expected and not a code bug.
- `swift package resolve` **works** on Linux and correctly fetches the Sparkle dependency.
- `swift package dump-package` **works** on Linux for validating `Package.swift` structure.
- The full build and runtime testing require **macOS with Xcode Command Line Tools**.

### Available tooling on Linux

| Tool | Command | Notes |
|------|---------|-------|
| Resolve dependencies | `swift package resolve` | Fetches/updates Sparkle binary artifact |
| Validate package manifest | `swift package dump-package` | Outputs JSON; exit 0 = valid |
| Lint | `swiftlint lint Sources/` | Runs SwiftLint on project sources only (exclude `.build/`) |

### Linting

Run `swiftlint lint Sources/` to lint only project source files. Running without the `Sources/` path argument will also lint Sparkle test files under `.build/`, producing noise. There is no `.swiftlint.yml` config in the repo; SwiftLint uses its defaults.

### Build (macOS only)

- Development build: `swift build`
- Release build: `swift build -c release`
- Full app bundle with signing: `./build.sh` (requires `DOCKPIN_SIGN_ID`, `DOCKPIN_APPLE_ID`, `DOCKPIN_TEAM_ID` env vars)

### What agents can do on Linux

1. Edit Swift source files and validate syntax via SwiftLint
2. Resolve and update package dependencies
3. Validate `Package.swift` structure
4. Review and modify `Info.plist`, `build.sh`, and documentation
