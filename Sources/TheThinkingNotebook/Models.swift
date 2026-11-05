import Foundation

struct ThreadMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case thinker
        case writer
    }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

enum MarginSide: String, Codable, Hashable {
    case left
    case right
}

/// One margin thought, anchored to a quote from the note, with its follow-up thread.
/// Thoughts live only in the margins; nothing here ever changes the note's text.
struct Thought: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Verbatim text from the note this thought is about. Empty = about the whole note.
    var quote: String
    var messages: [ThreadMessage]
    var createdAt = Date()
    var dismissed = false
    /// Optional so notes saved before two margins existed still load.
    var side: MarginSide?
    /// The highlighted passage this thought came from: the only note text Claude saw.
    var passage: String?

    var resolvedSide: MarginSide { side ?? .right }

    var opening: String { messages.first?.text ?? "" }
    var replyCount: Int { max(0, messages.count - 1) }
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var body: String = ""
    var thoughts: [Thought] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// The note's .md file in the notes folder; nil until it has been saved once.
    var fileName: String?

    var title: String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line = firstLine else { return "Untitled" }
        let stripped = line.drop { $0 == "#" || $0 == " " }
        let title = String(stripped.isEmpty ? Substring(line) : stripped)
        return title.count > 60 ? String(title.prefix(60)) + "…" : title
    }

    var openThoughts: [Thought] { thoughts.filter { !$0.dismissed } }
}
