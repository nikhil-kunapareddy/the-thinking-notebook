import AppKit
import SwiftUI

enum Theme {
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    // AppKit colors (the editor is an NSTextView)
    static let paperNS = dynamic(0xFBF8F1, 0x1C1B19)
    static let textNS = dynamic(0x2A2622, 0xE8E3D9)
    /// Claude's margin notes: light white on the dark page, soft graphite on the light page.
    static let inkNS = dynamic(0x3B3732, 0xF1EEE9)
    static let highlightNS = dynamic(0x3B3732, 0xF1EEE9).withAlphaComponent(0.14)
    static let ruleNS = dynamic(0xE7DECE, 0x35312B)
    static let cardNS = dynamic(0xF4EEE2, 0x262420)
    static let mutedNS = dynamic(0x8A8174, 0x8F877B)
    static let placeholderNS = dynamic(0xB8AF9F, 0x5F5A52)

    // SwiftUI colors
    static let paper = Color(nsColor: paperNS)
    static let text = Color(nsColor: textNS)
    static let ink = Color(nsColor: inkNS)
    static let rule = Color(nsColor: ruleNS)
    static let card = Color(nsColor: cardNS)
    static let muted = Color(nsColor: mutedNS)

    static let bodySize: CGFloat = 17

    static func bodyFont(size: CGFloat = bodySize) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let serif = base.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: serif, size: size) ?? base
        }
        return base
    }

    static func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.paragraphSpacing = 8
        return p
    }

    static func bodyAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont(size: size), .foregroundColor: textNS, .paragraphStyle: bodyParagraph()]
    }

    /// Claude's margin notes: SF Rounded, at the size set in Settings → Appearance.
    static func inkFont(_ size: Double) -> Font { .system(size: size, design: .rounded) }

    static func writerFont(size: CGFloat = 13) -> Font {
        .system(size: size, design: .serif)
    }
}

/// SwiftUI's `@State` property wrapper, spelled so it bypasses the `@State` macro in the
/// macOS 27 SDK. That macro's plugin ships only with Xcode, and this project builds with the
/// Command Line Tools alone.
typealias ViewState = SwiftUI.State
