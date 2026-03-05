import AppKit
import CoreGraphics

extension NSScreen {
    var dockPinDisplayID: CGDirectDisplayID? {
        // Use the documented AppKit mechanism that works on our deployment target (macOS 13+):
        // NSScreen.deviceDescription["NSScreenNumber"] -> CGDirectDisplayID.
        //
        // Newer SDKs may offer NSScreen.cgDirectDisplayID, but its availability may be higher
        // than our deployment target. Keeping this path avoids availability/version checks.
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let num = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
        if let id = deviceDescription[key] as? CGDirectDisplayID {
            return id
        }
        return nil
    }
}
