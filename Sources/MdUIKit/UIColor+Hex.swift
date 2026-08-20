#if canImport(UIKit)
import UIKit

public extension UIColor {
    /// sRGB color from a 6-digit hex value (0xRRGGBB). The UIKit-side
    /// counterpart of `CodeColorScheme`'s platform-neutral `UInt32` storage
    /// (mirrors `NSColor.hex` on macOS).
    static func hex(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
#endif
