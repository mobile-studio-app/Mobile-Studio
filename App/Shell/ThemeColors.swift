import UIKit

/// Changes when the colour theme does, so views re-resolve their theme colours (a trait change
/// makes UIKit resolve dynamic colours again).
struct ThemeRevisionTrait: UITraitDefinition {
    static let defaultValue = 0
}

/// The editor theme's workbench colours for the app's own chrome: the side bar, activity bar,
/// lists, inputs and buttons. The editor page sends them (Editor/src/theme.js chromeColors)
/// whenever the theme changes.
enum ThemeColors {
    static let didChange = Notification.Name("DuoCodeThemeColorsDidChange")
    private static var values: [String: UIColor] = [:]
    private static var revision = 0
    private(set) static var isDark = true

    /// A colour that follows the theme, falling back to `fallback` (Dark+).
    static func color(_ key: String, _ fallback: UIColor) -> UIColor {
        UIColor { traits in
            _ = traits[ThemeRevisionTrait.self]
            return values[key] ?? fallback
        }
    }

    static func apply(_ colors: [String: Any], dark: Bool) {
        var parsed: [String: UIColor] = [:]
        for (key, value) in colors {
            if let text = value as? String, let color = parse(text) { parsed[key] = color }
        }
        values = parsed
        isDark = dark
        revision += 1
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.traitOverrides[ThemeRevisionTrait.self] = revision
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// "#rgb", "#rrggbb" or "#rrggbbaa".
    static func parse(_ text: String) -> UIColor? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
