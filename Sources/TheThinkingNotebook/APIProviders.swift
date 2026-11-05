import Foundation

// MARK: - HTTP helpers

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 180
        return URLSession(configuration: c)
    }()

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Sends a request and returns (status, parsed JSON object or nil, raw body).
    static func send(_ request: URLRequest, provider: String) async throws -> (Int, [String: Any]?, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, try? JSONSerialization.jsonObject(with: data) as? [String: Any], data)
        } catch let e as URLError {
            throw connectionError(e, provider: provider)
        }
    }

    static func lines(_ request: URLRequest, provider: String) async throws -> (Int, URLSession.AsyncBytes) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, bytes)
        } catch let e as URLError {
            throw connectionError(e, provider: provider)
        }
    }

    static func connectionError(_ e: URLError, provider: String) -> LLMError {
        switch e.code {
        case .cannotConnectToHost, .cannotFindHost:
            if provider == ProviderKind.ollama.label {
                return .failed("Ollama isn't running. Open the Ollama app (or run `ollama serve`), then try again.")
            }
            return .failed("Couldn't reach \(provider). Check the endpoint URL in Settings → AI.")
        case .notConnectedToInternet, .networkConnectionLost:
            return .failed("No internet connection, so \(provider) can't be reached.")
        case .timedOut:
            return .failed("\(provider) took too long to answer.")
        default:
            return .failed("\(provider): \(e.localizedDescription)")
        }
    }

    /// A readable message from an error response body.
    static func message(status: Int, data: Data, provider: String) -> String {
        var detail = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            let dict = (obj as? [String: Any]) ?? (obj as? [[String: Any]])?.first ?? [:]
            if let err = dict["error"] as? [String: Any], let m = err["message"] as? String { detail = m }
            else if let m = dict["error"] as? String { detail = m }
            else if let m = dict["message"] as? String { detail = m }
        }
        if detail.isEmpty { detail = String(decoding: data.prefix(300), as: UTF8.self) }
        switch status {
        case 401, 403: return "\(provider) rejected the API key. Check it in Settings → AI. (\(detail))"
        case 404: return "\(provider) doesn't know that model or endpoint. Check Settings → AI. (\(detail))"
        case 429: return "\(provider) is rate-limiting or out of credit. (\(detail))"
        default: return "\(provider) error \(status): \(detail)"
        }
    }
}

// MARK: - Anthropic

/// Claude through the Anthropic API directly (raw HTTP; there is no official Swift SDK).
struct AnthropicAPI: LLMProvider {
    let key: String
    let model: String
    private let base = "https://api.anthropic.com/v1"
    private let label = ProviderKind.anthropic.label

    /// Models that accept server-side refusal fallbacks in their "default" form.
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    private var usesFallback: Bool { Self.fallbackModels.contains(model) }
    private var supportsEffort: Bool {
        !["haiku-4", "-3-", "sonnet-4-5", "opus-4-1", "opus-4-0"].contains { model.contains($0) }
    }

    private var headers: [String: String] {
        var h = ["x-api-key": key, "anthropic-version": "2026-10-21"]
        if usesFallback { h["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        return h
    }

    private func body(prompt: String, system: String, effort: String, schema: [String: Any]?, stream: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": stream ? 64000 : 16000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        var config: [String: Any] = [:]
        if supportsEffort { config["effort"] = effort }
        if let schema { config["format"] = ["type": "json_schema", "schema": schema] }
        if !config.isEmpty { b["output_config"] = config }
        if usesFallback { b["fallbacks"] = "default" }
        if stream { b["stream"] = true }
        return b
    }

    func structured(prompt: String, system: String, schema: String, effort: String) async throws -> [String: Any] {
        let schemaObj = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        let request = try HTTP.post(URL(string: "\(base)/messages")!, headers: headers,
                                    body: body(prompt: prompt, system: system, effort: effort, schema: schemaObj, stream: false))
        let (status, obj, data) = try await HTTP.send(request, provider: label)
        guard status == 200, let obj else { throw LLMError.failed(HTTP.message(status: status, data: data, provider: label)) }
        if obj["stop_reason"] as? String == "refusal" {
            throw LLMError.failed("Claude declined to comment on this passage.")
        }
        let text = ((obj["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return try JSONExtract.object(from: text)
    }

    func stream(prompt: String, system: String, effort: String,
                onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let request = try HTTP.post(URL(string: "\(base)/messages")!, headers: headers,
                                    body: body(prompt: prompt, system: system, effort: effort, schema: nil, stream: true))
        let (status, bytes) = try await HTTP.lines(request, provider: label)
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw LLMError.failed(HTTP.message(status: status, data: data, provider: label))
        }
        var full = ""
        var refused = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    full += text
                    let snapshot = full
                    await MainActor.run { onText(snapshot) }
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" { refused = true }
            case "error":
                let m = ((event["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                throw LLMError.failed("\(label): \(m)")
            default:
                break
            }
        }
        if refused && full.isEmpty { throw LLMError.failed("Claude declined to reply in this thread.") }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listModels() async throws -> [String] {
        var r = URLRequest(url: URL(string: "\(base)/models?limit=100")!)
        for (k, v) in headers where k != "anthropic-beta" { r.setValue(v, forHTTPHeaderField: k) }
        let (status, obj, data) = try await HTTP.send(r, provider: label)
        guard status == 200, let obj else { throw LLMError.failed(HTTP.message(status: status, data: data, provider: label)) }
        return ((obj["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - OpenAI-compatible (OpenAI, Gemini, xAI, Mistral, DeepSeek, Groq, OpenRouter, Ollama, custom)

struct OpenAICompatible: LLMProvider {
    let kind: ProviderKind
    let base: URL
    let key: String?
    let model: String

    private var headers: [String: String] {
        guard let key, !key.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    private var effortValue: (String) -> String? {
        { effort in kind.supportsEffort ? (effort == "xhigh" || effort == "max" ? "high" : effort) : nil }
    }

    private static let jsonHint = """

    Reply with only a JSON object of the form {"thoughts": [{"quote": "...", "text": "..."}]}.
    """

    private func messages(_ prompt: String, _ system: String, json: Bool) -> [[String: String]] {
        [["role": "system", "content": system],
         ["role": "user", "content": json ? prompt + Self.jsonHint : prompt]]
    }

    func structured(prompt: String, system: String, schema: String, effort: String) async throws -> [String: Any] {
        let schemaObj = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? [:]
        let strict: [String: Any] = ["type": "json_schema",
                                     "json_schema": ["name": "margin_notes", "schema": schemaObj, "strict": true]]
        // Not every server supports every option, so step down on a 400.
        let attempts: [(format: [String: Any]?, effort: Bool)] = [
            (strict, true), (["type": "json_object"], false), (nil, false),
        ]
        var lastError = ""
        for attempt in attempts {
            var body: [String: Any] = ["model": model, "messages": messages(prompt, system, json: true)]
            if let f = attempt.format { body["response_format"] = f }
            if attempt.effort, let e = effortValue(effort) { body["reasoning_effort"] = e }
            let request = try HTTP.post(base.appendingPathComponent("chat/completions"), headers: headers, body: body)
            let (status, obj, data) = try await HTTP.send(request, provider: kind.label)
            if status == 400 || status == 422 {
                lastError = HTTP.message(status: status, data: data, provider: kind.label)
                continue
            }
            guard status == 200, let obj else { throw LLMError.failed(HTTP.message(status: status, data: data, provider: kind.label)) }
            return try JSONExtract.object(from: Self.content(of: obj))
        }
        throw LLMError.failed(lastError)
    }

    func stream(prompt: String, system: String, effort: String,
                onText: @escaping @MainActor (String) -> Void) async throws -> String {
        var lastError = ""
        for useEffort in [true, false] {
            var body: [String: Any] = ["model": model, "messages": messages(prompt, system, json: false), "stream": true]
            if useEffort, let e = effortValue(effort) { body["reasoning_effort"] = e }
            else if useEffort { continue }
            let request = try HTTP.post(base.appendingPathComponent("chat/completions"), headers: headers, body: body)
            let (status, bytes) = try await HTTP.lines(request, provider: kind.label)
            if status != 200 {
                var data = Data()
                for try await b in bytes { data.append(b) }
                lastError = HTTP.message(status: status, data: data, provider: kind.label)
                if status == 400 || status == 422 { continue }
                throw LLMError.failed(lastError)
            }
            var full = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choice = (event["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any],
                      let text = delta["content"] as? String, !text.isEmpty else { continue }
                full += text
                let snapshot = full
                await MainActor.run { onText(snapshot) }
            }
            return full.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw LLMError.failed(lastError)
    }

    func listModels() async throws -> [String] {
        var r = URLRequest(url: base.appendingPathComponent("models"))
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (status, obj, data) = try await HTTP.send(r, provider: kind.label)
        guard status == 200, let obj else { throw LLMError.failed(HTTP.message(status: status, data: data, provider: kind.label)) }
        let ids = ((obj["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        return ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.sorted()
    }

    private static func content(of obj: [String: Any]) -> String {
        guard let message = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return "" }
        if let s = message["content"] as? String { return s }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}
