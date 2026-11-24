import AppKit

enum WorkspaceStyle {
    static let workspace = color(light: 0xF4F4F2, dark: 0x1C1E21)
    static let sidebar = color(light: 0xECEDEA, dark: 0x191B1E)
    static let panel = color(light: 0xFFFFFF, dark: 0x23262A)
    static let textPrimary = color(light: 0x24272B, dark: 0xECEEF0)
    static let textSecondary = color(light: 0x60666E, dark: 0xADB3BB, highContrast: .labelColor)
    static let accent = color(light: 0x4F657B, dark: 0xA6BCD0)
    static let onAccent = color(light: 0xFFFFFF, dark: 0x23262A)
    static let divider = color(light: 0xD5D8DC, dark: 0x363B42, highContrast: .labelColor)
    static let controlBoundary = color(light: 0x7B828C, dark: 0x7A838F)
    static let success = color(light: 0x3B6A51, dark: 0x99C4AB)
    static let warning = color(light: 0x805C20, dark: 0xD7BA79)
    static let error = color(light: 0xA53A42, dark: 0xEBA3A9)

    private static func color(light: UInt32, dark: UInt32, highContrast: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                    .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            if let highContrast, match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua {
                return highContrast
            }
            let value = match == .darkAqua || match == .accessibilityHighContrastDarkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}
