import AppKit
import Foundation

/// UserDefaults keys. API keys are not here: they live in the Keychain.
enum Prefs {
    // AI
    static let provider = "provider"
    static let model = "model"                // Claude Code's model (kept from v1)
    static let readEffort = "readEffort"      // margin notes
    static let threadEffort = "threadEffort"  // thread replies
    static let claudePath = "claudePath"
    static let codexPath = "codexPath"
    static func modelKey(_ kind: ProviderKind) -> String { kind == .claudeCode ? model : "model.\(kind.rawValue)" }
    static func baseURLKey(_ kind: ProviderKind) -> String { "baseURL.\(kind.rawValue)" }

    // General
    static let sendKey = "sendKey"                       // "return" | "commandReturn"
    static let seesWholeNote = "seesWholeNote"           // false = only the highlight
    static let customInstructions = "customInstructions"

    // Notes
    static let notesFolder = "notesFolder"
    static let migratedLegacyNotes = "migratedLegacyNotes"

    // Appearance
    static let theme = "theme"                // "system" | "light" | "dark"
    static let pageFontSize = "pageFontSize"
    static let marginFontSize = "marginFontSize"

    static let defaultModel = "claude-opus-5-5"

    static func register() {
        UserDefaults.standard.register(defaults: [
            provider: ProviderKind.claudeCode.rawValue,
            model: defaultModel,
            readEffort: "low",
            threadEffort: "medium",
            sendKey: "return",
            seesWholeNote: false,
            customInstructions: "",
            theme: "system",
            pageFontSize: 17.0,
            marginFontSize: 14.0,
        ])
    }

    static var sendsWithCommand: Bool { UserDefaults.standard.string(forKey: sendKey) == "commandReturn" }
    static var pageSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: pageFontSize)).clamped(12, 28) }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

/// Applies the Light / Dark / System choice to the whole app.
enum AppAppearance {
    @MainActor
    static func apply() {
        switch UserDefaults.standard.string(forKey: Prefs.theme) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
