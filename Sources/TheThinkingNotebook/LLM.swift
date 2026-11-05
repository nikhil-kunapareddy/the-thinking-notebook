import Foundation
import Security

/// Anything that can write margin notes: a local CLI, a local model, or a cloud API.
protocol LLMProvider {
    /// One request whose answer must be a JSON object matching `schema`.
    func structured(prompt: String, system: String, schema: String, effort: String) async throws -> [String: Any]
    /// One plain-text request; `onText` receives the reply so far as it arrives.
    func stream(prompt: String, system: String, effort: String,
                onText: @escaping @MainActor (String) -> Void) async throws -> String
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case failed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m), .failed(let m): return m
        case .badOutput(let detail): return "The model returned something unexpected: \(detail)"
        }
    }
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case claudeCode, codex, ollama
    case anthropic, openAI, gemini, xai, mistral, deepseek, groq, openRouter, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .ollama: return "Ollama"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .xai: return "xAI"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    static let local: [ProviderKind] = [.claudeCode, .codex, .ollama]
    static let cloud: [ProviderKind] = [.anthropic, .openAI, .gemini, .xai, .mistral, .deepseek, .groq, .openRouter, .custom]

    var isCLI: Bool { self == .claudeCode || self == .codex }
    var usesKey: Bool { !isCLI && self != .ollama }
    var keyRequired: Bool { usesKey && self != .custom }
    var editableBaseURL: Bool { self == .ollama || self == .custom }
    /// Providers whose API takes a reasoning-effort setting.
    var supportsEffort: Bool { [.claudeCode, .codex, .anthropic, .openAI, .gemini].contains(self) }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xai: return "https://api.x.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom, .claudeCode, .codex: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .claudeCode, .anthropic: return Prefs.defaultModel
        default: return ""
        }
    }

    /// Where to get credentials, shown under the key field.
    var keyHint: String {
        switch self {
        case .anthropic: return "Create a key at console.anthropic.com."
        case .openAI: return "Create a key at platform.openai.com."
        case .gemini: return "Create a key at aistudio.google.com."
        case .xai: return "Create a key at console.x.ai."
        case .mistral: return "Create a key at console.mistral.ai."
        case .deepseek: return "Create a key at platform.deepseek.com."
        case .groq: return "Create a key at console.groq.com."
        case .openRouter: return "Create a key at openrouter.ai."
        case .custom: return "Any OpenAI-compatible endpoint, e.g. Azure OpenAI, LM Studio, Together. Key is optional."
        case .claudeCode: return "Uses your Claude Code login. Run `claude` once in Terminal to sign in."
        case .codex: return "Uses your Codex login. Run `codex login` in Terminal to sign in."
        case .ollama: return "Runs on this Mac. Open the Ollama app, then `ollama pull <model>`."
        }
    }
}

enum LLM {
    static var kind: ProviderKind {
        ProviderKind(rawValue: UserDefaults.standard.string(forKey: Prefs.provider) ?? "") ?? .claudeCode
    }

    static func model(for kind: ProviderKind) -> String {
        let m = UserDefaults.standard.string(forKey: Prefs.modelKey(kind))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? kind.defaultModel : m
    }

    static func baseURL(for kind: ProviderKind) -> String {
        let saved = UserDefaults.standard.string(forKey: Prefs.baseURLKey(kind))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = (kind.editableBaseURL && !saved.isEmpty) ? saved : kind.defaultBaseURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// The provider chosen in Settings, ready to call.
    static func make(_ kind: ProviderKind = kind) throws -> LLMProvider {
        let model = model(for: kind)
        switch kind {
        case .claudeCode:
            return try ClaudeCLI.make()
        case .codex:
            return try CodexCLI.make()
        case .anthropic:
            guard let key = Keychain.get(kind.rawValue), !key.isEmpty else {
                throw LLMError.notConfigured("Add your Anthropic API key in Settings → AI.")
            }
            return AnthropicAPI(key: key, model: model)
        default:
            let key = Keychain.get(kind.rawValue)
            if kind.keyRequired, key?.isEmpty ?? true {
                throw LLMError.notConfigured("Add your \(kind.label) API key in Settings → AI.")
            }
            guard !model.isEmpty else {
                throw LLMError.notConfigured("Pick a \(kind.label) model in Settings → AI.")
            }
            guard let url = URL(string: baseURL(for: kind)), url.scheme != nil else {
                throw LLMError.notConfigured("Set a valid endpoint URL for \(kind.label) in Settings → AI.")
            }
            return OpenAICompatible(kind: kind, base: url, key: key, model: model)
        }
    }

    /// Models the provider offers, for the picker in Settings.
    static func listModels(_ kind: ProviderKind) async throws -> [String] {
        switch kind {
        case .claudeCode:
            return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case .codex:
            return []
        case .anthropic:
            guard let key = Keychain.get(kind.rawValue), !key.isEmpty else {
                throw LLMError.notConfigured("Add your API key first.")
            }
            return try await AnthropicAPI(key: key, model: "").listModels()
        default:
            guard let url = URL(string: baseURL(for: kind)) else { throw LLMError.notConfigured("Set the endpoint URL first.") }
            return try await OpenAICompatible(kind: kind, base: url, key: Keychain.get(kind.rawValue), model: "").listModels()
        }
    }
}

/// Pulls a JSON object out of a model reply, even if it's wrapped in prose or code fences.
enum JSONExtract {
    static func object(from text: String) throws -> [String: Any] {
        if let obj = parse(text) { return obj }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let obj = parse(String(text[start...end])) {
            return obj
        }
        throw LLMError.badOutput("no JSON in the reply")
    }

    private static func parse(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }
}

/// API keys, stored in the macOS Keychain (never in UserDefaults or the notes folder).
enum Keychain {
    private static let service = "app.thethinkingnotebook.apikeys"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
