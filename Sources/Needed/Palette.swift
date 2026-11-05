import AppKit
import SwiftUI

/// One of the twelve warm colors: `color` for rings and the glow, `tint` for
/// row backgrounds, `deep` for text on the tint. Colors may repeat between
/// contacts: they are labels in the menu, a signal never says who sent it.
struct PaletteColor {
    let name: String
    let color: UInt32
    let tint: UInt32
    let deep: UInt32

    /// The row background: the pastel `tint` on light paper, a dim wash of
    /// `color` on dark.
    var tintColor: Color { .dynamic(tint, mix(color, Color.darkPaper, 0.3)) }
    /// Text on the tint.
    var deepColor: Color { .dynamic(deep, mix(color, 0xFFFFFF, 0.45)) }
    /// Rings and swatches: the same in both appearances.
    var ringColor: Color { Color(hex: color) }
}

/// `a` with `t` of it turned into `b`, channel by channel.
private func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    var result: UInt32 = 0
    for shift: UInt32 in [16, 8, 0] {
        let x = Double((a >> shift) & 0xFF)
        let y = Double((b >> shift) & 0xFF)
        result |= UInt32((x + (y - x) * t).rounded()) << shift
    }
    return result
}

enum Palette {
    static let all: [PaletteColor] = [
        PaletteColor(name: tr("Коралловый"), color: 0xF07A62, tint: 0xFDE6E0, deep: 0xA8402B),
        PaletteColor(name: tr("Розовый"), color: 0xE86A9A, tint: 0xFBE2EC, deep: 0xA3305E),
        PaletteColor(name: tr("Голубой"), color: 0x4E9BD8, tint: 0xE0EEF9, deep: 0x22679E),
        PaletteColor(name: tr("Шалфей"), color: 0x6FAE7C, tint: 0xE3F1E6, deep: 0x39744A),
        PaletteColor(name: tr("Лавандовый"), color: 0x9B83DD, tint: 0xECE6FA, deep: 0x5E45A3),
        PaletteColor(name: tr("Медовый"), color: 0xE5A93B, tint: 0xFBF0DA, deep: 0x8A5E0E),
        PaletteColor(name: tr("Бирюзовый"), color: 0x3FB3A8, tint: 0xDDF3F0, deep: 0x1D6F68),
        // Appended, not merged in: indices are what settings store.
        PaletteColor(name: tr("Вишнёвый"), color: 0xC94A5E, tint: 0xF8E1E5, deep: 0x8E2638),
        PaletteColor(name: tr("Карамельный"), color: 0xC98B5E, tint: 0xF6E9DE, deep: 0x7D4F2C),
        PaletteColor(name: tr("Оливковый"), color: 0x9DA24A, tint: 0xEEF0DC, deep: 0x5C601F),
        PaletteColor(name: tr("Индиго"), color: 0x6474D6, tint: 0xE4E7F8, deep: 0x3640A0),
        PaletteColor(name: tr("Грифельный"), color: 0x7E8C99, tint: 0xE8ECEF, deep: 0x46525E),
    ]

    static func at(_ index: Int) -> PaletteColor {
        all[((index % all.count) + all.count) % all.count]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// A light and a dark value, picked by the popover's appearance (the system's).
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (light: CGFloat, dark: CGFloat) = (1, 1)) -> Color {
        Color(nsColor: .dynamic(light, dark, alpha: alpha))
    }

    static let darkPaper: UInt32 = 0x2A211D

    // Warm paper and brown ink; at night, dark cocoa and cream.
    static let ink = dynamic(0x3B2A23, 0xF3E6DC)
    static let muted = dynamic(0x6E554A, 0xC7B0A2)
    static let faint = dynamic(0x7A6156, 0xA8917F)
    static let paper = dynamic(0xFFFBF6, darkPaper)
    static let field = dynamic(0xF8EFE6, 0x372C27)
    static let well = dynamic(0xF2E6DA, 0x40342E)
    /// The chosen tab, lifted off the well.
    static let raised = dynamic(0xFFFBF6, 0x5A4A42)
    /// Text fields.
    static let input = dynamic(0xFFFFFF, 0x221B18)
    static let link = dynamic(0xB83A4E, 0xF28C9B)
    static let heart = dynamic(0xE0596B, 0xEC6F80)
    /// The heart's pale background and the text on it.
    static let heartSoft = dynamic(0xFDE3E6, 0x4A2B31)
    static let heartDeep = dynamic(0x8E2537, 0xFFB8C2)
    static let ok = dynamic(0x39744A, 0x8DCB9B)
    static let danger = dynamic(0xB3261E, 0xFF8A80)
    static let hairline = dynamic(0x54301E, 0xFFEBDC, alpha: (0.22, 0.16))
    static let switchOn = Color(hex: 0x3FA05A)
    static let star = dynamic(0xD99A1E, 0xE8B54F)
    static let starOff = dynamic(0xB9A596, 0x7D6A5E)
    /// "Кому-нибудь на свете": peach, pink and lilac.
    static let anyone = [dynamic(0xFBE3D2, 0x4A3226), dynamic(0xFCE6EA, 0x4A2C33), dynamic(0xF3E4F3, 0x3E2C40)]
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (light: CGFloat, dark: CGFloat) = (1, 1)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: alpha.dark)
                : NSColor(hex: light, alpha: alpha.light)
        }
    }

    /// The windows' background, under the title bar too.
    static let paper = dynamic(0xFFFBF6, Color.darkPaper)
}
