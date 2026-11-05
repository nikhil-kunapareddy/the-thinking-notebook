import Foundation
import Observation
import SwiftUI

// MARK: - Prompts

/// By default the model sees only text the writer highlighted (plus its own margin threads).
/// With "What the AI sees" set to include the note, the full note is sent as background.
enum Prompts {
    static var seesWholeNote: Bool { UserDefaults.standard.bool(forKey: Prefs.seesWholeNote) }

    static var system: String {
        var s = base.replacingOccurrences(
            of: "{SEES}",
            with: seesWholeNote
                ? "You also get the rest of the note as background, but your notes are about the highlighted passage."
                : "You see only the highlighted passage, not the rest of the note.")
        if !seesWholeNote {
            s = s.replacingOccurrences(of: "{GUESS}", with: "\n- You only see a passage. Don't guess at what the rest of the note says.")
        } else {
            s = s.replacingOccurrences(of: "{GUESS}", with: "\n- Use the rest of the note to catch contradictions and missing links, but keep your notes on the passage.")
        }
        let custom = (UserDefaults.standard.string(forKey: Prefs.customInstructions) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            s += "\n\nThe writer's standing instructions for you. Follow them, except that you still never rewrite their notes:\n<instructions>\n\(custom)\n</instructions>"
        }
        return s
    }

    private static let base = """
    You are the thinking partner inside The Thinking Notebook, a notebook app for Mac. When the writer highlights a passage of their notes and asks you to look, you leave short notes in the margin beside it. {SEES}

    Your job is to make them a better thinker, not to think for them.

    How you help:
    - Ask the question they haven't asked themselves: the hidden assumption, the missing number, the case they skipped, the claim that doesn't follow, the "why" behind a decision.
    - When they are clearly stuck or confused, explain the smallest piece that gets them moving, then hand the thinking back to them.
    - If something they wrote is wrong, say so plainly and point at why, without supplying the full corrected answer unless they ask for it.
    - Match the kind of writing. In study notes, check understanding and probe the reasoning. In design or engineering notes, push on trade-offs, edge cases and evidence. In personal notes, be a calm, honest friend: reflect and ask, don't fix.{GUESS}

    What you never do:
    - Rewrite their notes, write their work for them, or hand over every answer.
    - Praise, cheerlead, summarize their words back to them, or open with preamble.
    - Lecture. A margin note is one to three sentences.

    Voice: plain, warm, direct, a little dry. Write like a sharp friend scribbling in the margin, in the same language as the passage. No markdown headings, no bullet lists, no emoji.
    """

    static let thoughtsSchema = """
    {"type":"object","properties":{"thoughts":{"type":"array","items":{"type":"object","properties":{"quote":{"type":"string"},"text":{"type":"string"}},"required":["quote","text"],"additionalProperties":false}}},"required":["thoughts"],"additionalProperties":false}
    """

    private static func noteBlock(_ note: String?) -> String {
        guard let note, seesWholeNote else { return "" }
        return "Here is the whole note, for background:\n\n<note>\n\(note)\n</note>\n\n"
    }

    static func passage(_ passage: String, note: String?, earlier: [Thought]) -> String {
        var margin = ""
        if !earlier.isEmpty {
            let lines = earlier.suffix(12).map { t -> String in
                let flag = t.dismissed ? " (the writer dismissed this; don't raise it again)" : ""
                return "- on \"\(t.quote)\": \(t.opening)\(flag)"
            }
            margin = "\nYou already left these notes on this passage, so don't repeat or rephrase them:\n<margin>\n\(lines.joined(separator: "\n"))\n</margin>\n"
        }
        return """
        \(noteBlock(note))The writer highlighted this passage and asked you to look at it:

        <passage>
        \(passage)
        </passage>
        \(margin)
        Leave the margin notes that would most help them think about it: usually one, two only if two separate things clearly need attention.

        For each thought:
        - quote: copy, character for character, 3 to 12 consecutive words from the passage that the thought is about.
        - text: the margin note itself.
        """
    }

    static func thread(_ thought: Thought, note: String?) -> String {
        let passage = thought.passage ?? thought.quote
        let lines = thought.messages.map { m in
            "\(m.role == .thinker ? "You" : "Writer"): \(m.text)"
        }
        return """
        \(noteBlock(note))The writer highlighted this passage:

        <passage>
        \(passage)
        </passage>

        A margin thread about "\(thought.quote)":

        <thread>
        \(lines.joined(separator: "\n\n"))
        </thread>

        Write your next reply in this thread, answering the writer's latest message. Follow the thought with them. If they push back, take it seriously: change your mind if they're right, hold your ground with a reason if they're not. If they ask why, explain briefly. If they ask you outright for an answer, you can give it, then point at what to check or try next. Keep it to a few sentences. Plain text; include a short code snippet only if they ask for code.
        """
    }
}

// MARK: - Text helpers

enum TextMatch {
    /// Finds `quote` inside `range` of `body`, tolerating curly quotes, dashes, case and stray
    /// ellipses. Returns the exact text as it appears in `body`.
    static func resolve(_ quote: String, in body: String, within range: NSRange) -> String? {
        var q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’…. "))
        guard !q.isEmpty else { return nil }

        let nsBody = body as NSString
        let normBody = normalize(body) as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: nsBody.length))
        for candidate in [q, firstWords(q, 6), firstWords(q, 4)] where !candidate.isEmpty {
            let r = normBody.range(of: normalize(candidate), options: [.caseInsensitive], range: safe)
            if r.location != NSNotFound { return nsBody.substring(with: r) }
        }
        return nil
    }

    private static func firstWords(_ s: String, _ n: Int) -> String {
        let words = s.split(separator: " ")
        guard words.count > n else { return "" }
        return words.prefix(n).joined(separator: " ")
    }

    /// One-for-one character swaps, so UTF-16 offsets stay aligned with the original.
    private static func normalize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar {
            case "\u{2018}", "\u{2019}": return "'"
            case "\u{201C}", "\u{201D}": return "\""
            case "\u{2013}", "\u{2014}": return "-"
            case "\u{00A0}": return " "
            default: return scalar
            }
        }))
    }
}

// MARK: - Per-note brain

/// A highlighted passage Claude is looking at right now.
struct PendingPass: Identifiable, Equatable {
    let id = UUID()
    let y: CGFloat
    let side: MarginSide
}

/// Sends highlighted passages to Claude and runs margin threads for one note.
/// It only ever adds to `note.thoughts`; it never edits `note.body`.
@MainActor
@Observable
final class NoteBrain {
    let noteID: UUID
    @ObservationIgnored private weak var store: NoteStore?

    /// Highlighted passages waiting on Claude, shown as placeholders in the margin.
    private(set) var pending: [PendingPass] = []
    /// Partial replies while they stream in, by thought.
    private(set) var streaming: [UUID: String] = [:]
    var error: String?

    @ObservationIgnored private var replyTasks: [UUID: Task<Void, Never>] = [:]

    init(noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        self.store = store
    }

    private var note: Note? { store?.note(noteID) }

    // MARK: Highlight + Return

    /// The writer highlighted `range` and pressed Return. Only that passage goes to Claude.
    func look(at range: NSRange, y: CGFloat) {
        guard let note else { return }
        let body = note.body as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: body.length))
        let passage = body.substring(with: safe)
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let fallbackQuote = Self.firstLine(of: passage)
        let side = chooseSide(for: fallbackQuote)
        let pass = PendingPass(y: y, side: side)
        let earlier = note.thoughts.filter { !$0.quote.isEmpty && passage.contains($0.quote) }
        let prompt = Prompts.passage(passage, note: note.body, earlier: earlier)

        withAnimation(.easeOut(duration: 0.2)) { pending.append(pass) }
        error = nil
        Task { [weak self] in
            guard let self else { return }
            defer { withAnimation(.easeOut(duration: 0.2)) { self.pending.removeAll { $0.id == pass.id } } }
            do {
                let llm = try LLM.make()
                let effort = UserDefaults.standard.string(forKey: Prefs.readEffort) ?? "low"
                let result = try await llm.structured(
                    prompt: prompt, system: Prompts.system,
                    schema: Prompts.thoughtsSchema, effort: effort)
                let items = (result["thoughts"] as? [[String: Any]]) ?? []
                self.addThoughts(items.prefix(2), passage: passage, range: safe, fallbackQuote: fallbackQuote)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addThoughts(_ items: ArraySlice<[String: Any]>, passage: String,
                             range: NSRange, fallbackQuote: String) {
        let current = note?.body ?? passage
        var new: [Thought] = []
        for item in items {
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let quote = TextMatch.resolve(item["quote"] as? String ?? "", in: current, within: range)
                ?? fallbackQuote
            var t = Thought(quote: quote, messages: [ThreadMessage(role: .thinker, text: text)])
            t.passage = passage
            t.side = chooseSide(for: quote, in: current, alsoPlaced: new)
            new.append(t)
        }
        withAnimation(.easeOut(duration: 0.35)) {
            store?.update(noteID, touch: false) { $0.thoughts.append(contentsOf: new) }
        }
    }

    private static func firstLine(of passage: String) -> String {
        let line = passage
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 160 ? String(line.prefix(160)) : line
    }

    // MARK: Margins

    /// Picks the margin with fewer notes near this quote, so notes spread across both sides
    /// instead of piling up in one. Ties go to the right margin.
    func chooseSide(for quote: String, in body: String? = nil, alsoPlaced: [Thought] = []) -> MarginSide {
        guard let note else { return .right }
        let text = (body ?? note.body) as NSString
        func offset(_ q: String) -> Int? {
            guard !q.isEmpty else { return nil }
            let r = text.range(of: q)
            return r.location == NSNotFound ? nil : r.location
        }
        guard let here = offset(quote) else { return .right }
        let nearby = 400  // characters, roughly five or six lines
        var left = 0, right = 0
        for t in note.openThoughts + alsoPlaced {
            guard let o = offset(t.quote), abs(o - here) <= nearby else { continue }
            if t.resolvedSide == .left { left += 1 } else { right += 1 }
        }
        return left < right ? .left : .right
    }

    func move(_ thoughtID: UUID, to side: MarginSide) {
        withAnimation(.snappy(duration: 0.28)) {
            store?.updateThought(noteID, thoughtID) { $0.side = side }
        }
    }

    // MARK: Threads

    func reply(to thoughtID: UUID, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store?.updateThought(noteID, thoughtID) {
            $0.messages.append(ThreadMessage(role: .writer, text: trimmed))
        }
        startReply(thoughtID)
    }

    func dismiss(_ thoughtID: UUID) {
        replyTasks[thoughtID]?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            store?.updateThought(noteID, thoughtID) { $0.dismissed = true }
        }
    }

    private func startReply(_ id: UUID) {
        replyTasks[id]?.cancel()
        streaming[id] = ""
        error = nil
        replyTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.streaming[id] = nil }
            do {
                guard let note = self.note, let thought = note.thoughts.first(where: { $0.id == id }) else { return }
                let llm = try LLM.make()
                let effort = UserDefaults.standard.string(forKey: Prefs.threadEffort) ?? "medium"
                let reply = try await llm.stream(
                    prompt: Prompts.thread(thought, note: note.body),
                    system: Prompts.system, effort: effort
                ) { [weak self] partial in
                    self?.streaming[id] = partial
                }
                guard !reply.isEmpty else { return }
                self.store?.updateThought(self.noteID, id) {
                    $0.messages.append(ThreadMessage(role: .thinker, text: reply))
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
