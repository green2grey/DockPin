import AppKit
import CoreGraphics

extension NSScreen {
    var dockPinDisplayID: CGDirectDisplayID? {
        // NSScreen.cgDirectDisplayID may not be available on our deployment target (macOS 13+).
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
