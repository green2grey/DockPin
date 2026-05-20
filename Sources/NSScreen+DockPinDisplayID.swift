import AppKit
import CoreGraphics

extension NSScreen {
    var dockPinDisplayID: CGDirectDisplayID? {
        if #available(macOS 14.0, *) {
            return cgDirectDisplayID
        }

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
