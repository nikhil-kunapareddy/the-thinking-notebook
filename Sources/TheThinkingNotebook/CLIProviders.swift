import Foundation

// MARK: - Shared CLI plumbing

enum CLITool {
    /// Finds an executable: the path set in Settings, common install spots, then a login shell
    /// (GUI apps don't inherit the shell's PATH).
    static func locate(name: String, customPathKey: String, candidates: [String]) -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: customPathKey), !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        if let hit = candidates.map({ ($0 as NSString).expandingTildeInPath })
            .first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        if let found = loginShellLookup(name), fm.isExecutableFile(atPath: found) {
            return URL(fileURLWithPath: found)
        }
        return nil
    }

    private static func loginShellLookup(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return (path?.hasPrefix("/") ?? false) ? path : nil
    }

    /// Launches the tool, writes `stdin`, and hands each stdout line to `onLine`.
    /// Cancelling the calling task terminates the process. Returns (exit status, stderr).
    static func run(_ executable: URL, args: [String], stdin: String,
                    onLine: (String) async throws -> Void) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = AppPaths.workspace

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [executable.deletingLastPathComponent().path, "\(home)/.local/bin",
                     "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let stdinData = Data(stdin.utf8)
        let writer = Task.detached {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? inPipe.fileHandleForWriting.close()
        }
        let errReader = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        try await withTaskCancellationHandler {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                try await onLine(line)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        _ = await writer.value
        let err = String(decoding: await errReader.value, as: UTF8.self)
        await Task.detached { process.waitUntilExit() }.value
        try Task.checkCancellation()
        return (process.terminationStatus, err)
    }

    static func tail(_ text: String, lines: Int = 3) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }

    static func version(_ executable: URL) async -> String? {
        await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = executable
            p.arguments = ["--version"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

// MARK: - Claude Code

/// Runs the local Claude Code CLI headlessly (`claude -p`) with its existing login.
struct ClaudeCLI: LLMProvider {
    let executable: URL

    static func locate() -> URL? {
        CLITool.locate(name: "claude", customPathKey: Prefs.claudePath, candidates: [
            "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }

    static func make() throws -> ClaudeCLI {
        guard let url = locate() else {
            throw LLMError.notConfigured("Couldn't find the claude command. Install Claude Code and run `claude` once in Terminal to log in, or set its path in Settings → AI.")
        }
        return ClaudeCLI(executable: url)
    }

    func structured(prompt: String, system: String, schema: String, effort: String) async throws -> [String: Any] {
        var args = baseArgs(system: system, effort: effort)
        args += ["--output-format", "json", "--json-schema", schema]
        var resultLine: String?
        let (status, err) = try await CLITool.run(executable, args: args, stdin: prompt) { line in
            if line.hasPrefix("{") { resultLine = line }
        }
        guard let line = resultLine,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { throw failure(status, err) }
        try Self.checkError(obj)
        if let structured = obj["structured_output"] as? [String: Any] { return structured }
        if let text = obj["result"] as? String { return try JSONExtract.object(from: text) }
        throw LLMError.badOutput("missing structured output")
    }

    func stream(prompt: String, system: String, effort: String,
                onText: @escaping @MainActor (String) -> Void) async throws -> String {
        var args = baseArgs(system: system, effort: effort)
        args += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        var full = ""
        var final: [String: Any]?
        let (status, err) = try await CLITool.run(executable, args: args, stdin: prompt) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if type == "stream_event",
               let event = obj["event"] as? [String: Any],
               event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                full += text
                let snapshot = full
                await MainActor.run { onText(snapshot) }
            } else if type == "result" {
                final = obj
            }
        }
        guard let final else { throw failure(status, err) }
        try Self.checkError(final)
        if let text = final["result"] as? String, !text.isEmpty { full = text }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func baseArgs(system: String, effort: String) -> [String] {
        [
            "-p",
            "--system-prompt", system,
            "--model", LLM.model(for: .claudeCode),
            "--effort", effort,
            "--tools", "",              // pure conversation: no file, shell or web tools
            "--setting-sources", "",    // ignore the user's hooks, plugins and settings
            "--strict-mcp-config",      // don't start MCP servers
            "--no-session-persistence", // keep notebook calls out of Claude Code history
        ]
    }

    private func failure(_ status: Int32, _ err: String) -> LLMError {
        let tail = CLITool.tail(err)
        return .failed(tail.isEmpty ? "claude exited with status \(status)." : tail)
    }

    private static func checkError(_ obj: [String: Any]) throws {
        if obj["is_error"] as? Bool == true {
            throw LLMError.failed((obj["result"] as? String) ?? (obj["subtype"] as? String) ?? "Claude reported an error.")
        }
    }
}

// MARK: - Codex CLI

/// Runs OpenAI's Codex CLI headlessly (`codex exec`) with its existing login.
/// Codex has no separate system prompt, so the instructions go at the top of the prompt.
struct CodexCLI: LLMProvider {
    let executable: URL

    static func locate() -> URL? {
        CLITool.locate(name: "codex", customPathKey: Prefs.codexPath, candidates: [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex",
        ])
    }

    static func make() throws -> CodexCLI {
        guard let url = locate() else {
            throw LLMError.notConfigured("Couldn't find the codex command. Install the Codex CLI and run `codex login` in Terminal, or set its path in Settings → AI.")
        }
        return CodexCLI(executable: url)
    }

    func structured(prompt: String, system: String, schema: String, effort: String) async throws -> [String: Any] {
        let schemaFile = FileManager.default.temporaryDirectory.appendingPathComponent("ttn-schema-\(UUID().uuidString).json")
        try Data(schema.utf8).write(to: schemaFile)
        defer { try? FileManager.default.removeItem(at: schemaFile) }
        let text = try await run(prompt: prompt, system: system, effort: effort, schemaFile: schemaFile)
        return try JSONExtract.object(from: text)
    }

    func stream(prompt: String, system: String, effort: String,
                onText: @escaping @MainActor (String) -> Void) async throws -> String {
        // Codex reports the finished message, so the reply arrives all at once.
        let text = try await run(prompt: prompt, system: system, effort: effort, schemaFile: nil)
        await MainActor.run { onText(text) }
        return text
    }

    private func run(prompt: String, system: String, effort: String, schemaFile: URL?) async throws -> String {
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("ttn-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        var args = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules",
            "--sandbox", "read-only", "--color", "never",
            "-C", AppPaths.workspace.path,
            "-o", outFile.path,
            "-c", "model_reasoning_effort=\"\(effort == "xhigh" ? "high" : effort)\"",
        ]
        if let schemaFile { args += ["--output-schema", schemaFile.path] }
        let model = LLM.model(for: .codex)
        if !model.isEmpty { args += ["-m", model] }
        args.append("-")

        let full = """
        <instructions>
        \(system)

        Answer directly. Do not run commands, read files or browse.
        </instructions>

        \(prompt)
        """
        let (status, err) = try await CLITool.run(executable, args: args, stdin: full) { _ in }
        let text = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        if err.contains("401") || err.localizedCaseInsensitiveContains("sign in again") || err.contains("refresh token") {
            throw LLMError.notConfigured("Codex isn't logged in. Run `codex login` in Terminal, then try again.")
        }
        let tail = CLITool.tail(err)
        throw LLMError.failed(tail.isEmpty ? "codex exited with status \(status)." : tail)
    }
}
