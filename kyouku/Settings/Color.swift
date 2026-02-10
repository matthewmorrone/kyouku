import SwiftUI
import UIKit

extension UIColor {
    convenience init?(hexString: String) {
        var formatted = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if formatted.hasPrefix("#") {
            formatted.removeFirst()
        }
        guard formatted.count == 6 || formatted.count == 8 else {
            return nil
        }
        var value: UInt64 = 0
        guard Scanner(string: formatted).scanHexInt64(&value) else {
            return nil
        }
        let r, g, b, a: CGFloat
        if formatted.count == 8 {
            r = CGFloat((value & 0xFF000000) >> 24) / 255.0
            g = CGFloat((value & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((value & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(value & 0x000000FF) / 255.0
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            b = CGFloat(value & 0x0000FF) / 255.0
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    func hexString(includeAlpha: Bool = false) -> String? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        } else {
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }
}

extension Color {
    init(hexString: String, fallback: Color) {
        if let parsed = UIColor(hexString: hexString) {
            self = Color(parsed)
        } else {
            self = fallback
        }
    }

    func hexString(includeAlpha: Bool = false) -> String? {
        UIColor(self).hexString(includeAlpha: includeAlpha)
    }
}
