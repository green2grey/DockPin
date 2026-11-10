import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

#if DOCKPIN_DEV
// Dev builds only: draw the settings window to image files and exit, without starting the app.
if let flag = CommandLine.arguments.firstIndex(of: "--render-settings"),
   CommandLine.arguments.count > flag + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    let light = CommandLine.arguments.contains("--light")
    MainActor.assumeIsolated {
        SettingsPreviewRenderer.render(to: directory, appearance: light ? .aqua : .darkAqua)
    }
    exit(0)
}
#endif

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
