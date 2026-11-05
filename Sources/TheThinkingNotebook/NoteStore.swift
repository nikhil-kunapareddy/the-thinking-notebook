import AppKit
import Foundation
import Observation

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("The Thinking Notebook", isDirectory: true)
    }

    /// Where v1 kept notes as JSON. Read once to migrate, never written again.
    static var legacyNotes: URL { support.appendingPathComponent("Notes", isDirectory: true) }

    /// Empty working directory for CLI providers, so no project files or CLAUDE.md are picked up.
    static var workspace: URL { support.appendingPathComponent("Workspace", isDirectory: true) }

    static var defaultNotesFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thinking Notebook", isDirectory: true)
    }

    static var notesFolder: URL {
        if let path = UserDefaults.standard.string(forKey: Prefs.notesFolder), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultNotesFolder
    }

    static func ensure() {
        for dir in [support, workspace] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Margin notes for one Markdown file, kept in `<folder>/.thinking/<file>.json`.
private struct Sidecar: Codable {
    var id: UUID
    var createdAt: Date
    var thoughts: [Thought]
}

/// Notes are plain Markdown files in a folder you choose. Each file's name follows its first
/// line. Margin notes live in a hidden `.thinking` folder beside them, so the .md files stay clean.
@MainActor
@Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var folder: URL
    var selection: UUID?

    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastWritten: [UUID: Date] = [:]
    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        AppPaths.ensure()
        folder = AppPaths.notesFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        migrateLegacyNotes()
        if notes.isEmpty { _ = createNote() }
        selection = selection ?? sortedNotes.first?.id
    }

    var sortedNotes: [Note] { notes.sorted { $0.updatedAt > $1.updatedAt } }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func createNote() -> UUID {
        let note = Note()
        notes.append(note)
        selection = note.id
        return note.id
    }

    /// Moves the note's file (and its margin notes) to the Trash.
    func delete(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        if let name = note(id)?.fileName {
            try? fm.trashItem(at: mdURL(name), resultingItemURL: nil)
            try? fm.trashItem(at: sidecarURL(name), resultingItemURL: nil)
        }
        notes.removeAll { $0.id == id }
        if selection == id { selection = sortedNotes.first?.id }
        if notes.isEmpty { _ = createNote() }
    }

    /// Applies a change to one note, bumps its timestamp, and saves it shortly after.
    func update(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        if touch { notes[i].updatedAt = Date() }
        scheduleSave(id)
    }

    func updateThought(_ noteID: UUID, _ thoughtID: UUID, _ change: (inout Thought) -> Void) {
        update(noteID, touch: false) { note in
            guard let t = note.thoughts.firstIndex(where: { $0.id == thoughtID }) else { return }
            change(&note.thoughts[t])
        }
    }

    // MARK: Folder

    /// Points the app at another folder. With `bringNotes`, current notes are copied there first;
    /// the originals stay where they were.
    func switchFolder(to url: URL, bringNotes: Bool) {
        flush()
        let old = notes
        folder = url
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults.standard.set(url.path, forKey: Prefs.notesFolder)
        lastWritten.removeAll()
        load()
        if bringNotes {
            for var note in old where !(note.body.isEmpty && note.thoughts.isEmpty) {
                note.id = UUID()
                note.fileName = nil
                notes.append(note)
                write(note.id)
            }
        }
        if notes.isEmpty { _ = createNote() }
        selection = sortedNotes.first?.id
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Files

    private var sidecarDir: URL { folder.appendingPathComponent(".thinking", isDirectory: true) }
    private func mdURL(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private func sidecarURL(_ name: String) -> URL { sidecarDir.appendingPathComponent(name + ".json") }

    private static func baseName(for note: Note) -> String {
        var t = note.title
        if t == "Untitled" || t.isEmpty { return "Untitled" }
        if t.hasSuffix("…") { t = String(t.dropLast()) }
        let cleaned = t.map { "/:\\".contains($0) ? "-" : $0 }
        var s = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Untitled" : s
    }

    /// True if `fileName` is `base.md` or `base N.md`.
    private static func fileName(_ fileName: String, matches base: String) -> Bool {
        guard fileName.hasSuffix(".md") else { return false }
        let stem = String(fileName.dropLast(3))
        if stem == base { return true }
        guard stem.hasPrefix(base + " ") else { return false }
        return Int(stem.dropFirst(base.count + 1)) != nil
    }

    private func uniqueName(for base: String) -> String {
        var name = "\(base).md"
        var n = 2
        while fm.fileExists(atPath: mdURL(name).path) || notes.contains(where: { $0.fileName == name }) {
            name = "\(base) \(n).md"
            n += 1
        }
        return name
    }

    private func load() {
        var loaded: [Note] = []
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        for url in files where url.pathExtension.lowercased() == "md" {
            if let note = readNote(url) { loaded.append(note) }
        }
        notes = loaded
    }

    private func readNote(_ url: URL) -> Note? {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = url.lastPathComponent
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var note = Note()
        note.body = body
        note.fileName = name
        note.updatedAt = modified
        note.createdAt = modified
        if let data = try? Data(contentsOf: sidecarURL(name)),
           let side = try? decoder.decode(Sidecar.self, from: data) {
            note.id = side.id
            note.createdAt = side.createdAt
            note.thoughts = side.thoughts
        }
        lastWritten[note.id] = modified
        return note
    }

    private func scheduleSave(_ id: UUID, delay: Double = 0.6) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.pendingSaves[id] = nil
            self?.write(id)
        }
    }

    private func write(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[i]
        // A blank new note doesn't get a file until something is written in it.
        if note.fileName == nil, note.body.isEmpty, note.thoughts.isEmpty { return }

        let base = Self.baseName(for: note)
        var name = note.fileName ?? uniqueName(for: base)
        if let current = note.fileName, !Self.fileName(current, matches: base) {
            let renamed = uniqueName(for: base)
            try? fm.moveItem(at: mdURL(current), to: mdURL(renamed))
            if fm.fileExists(atPath: sidecarURL(current).path) {
                try? fm.moveItem(at: sidecarURL(current), to: sidecarURL(renamed))
            }
            name = renamed
        }

        do {
            try Data(note.body.utf8).write(to: mdURL(name), options: .atomic)
            if !note.thoughts.isEmpty || fm.fileExists(atPath: sidecarURL(name).path) {
                try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
                let side = Sidecar(id: note.id, createdAt: note.createdAt, thoughts: note.thoughts)
                try encoder.encode(side).write(to: sidecarURL(name), options: .atomic)
            }
        } catch {
            NSLog("The Thinking Notebook: couldn't save \(name): \(error.localizedDescription)")
        }
        if notes[i].fileName != name { notes[i].fileName = name }
        lastWritten[id] = Date()
    }

    /// Writes every note immediately. Called on quit and before switching folders.
    func flush() {
        let ids = Array(pendingSaves.keys)
        for (_, task) in pendingSaves { task.cancel() }
        pendingSaves.removeAll()
        for id in ids { write(id) }
    }

    /// Picks up edits made in other apps: changed, added and removed .md files.
    func reloadFromDisk() {
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }
        let onDisk = Set(mdFiles.map(\.lastPathComponent))

        for url in mdFiles {
            let name = url.lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let i = notes.firstIndex(where: { $0.fileName == name }) {
                let id = notes[i].id
                guard pendingSaves[id] == nil, modified > (lastWritten[id] ?? .distantPast).addingTimeInterval(1),
                      let fresh = readNote(url) else { continue }
                if fresh.body != notes[i].body { notes[i].body = fresh.body; notes[i].updatedAt = modified }
                if fresh.id == id, fresh.thoughts != notes[i].thoughts { notes[i].thoughts = fresh.thoughts }
                lastWritten[id] = modified
            } else if let fresh = readNote(url), !notes.contains(where: { $0.id == fresh.id }) {
                notes.append(fresh)
            }
        }
        notes.removeAll { n in
            guard let name = n.fileName else { return false }
            return !onDisk.contains(name) && pendingSaves[n.id] == nil
        }
        if let s = selection, note(s) == nil { selection = sortedNotes.first?.id }
        if notes.isEmpty { _ = createNote() }
    }

    // MARK: Migration

    /// Moves v1's JSON notes into the folder as Markdown, once. The old files are left as they were.
    private func migrateLegacyNotes() {
        guard !UserDefaults.standard.bool(forKey: Prefs.migratedLegacyNotes) else { return }
        defer { UserDefaults.standard.set(true, forKey: Prefs.migratedLegacyNotes) }
        let files = (try? fm.contentsOfDirectory(at: AppPaths.legacyNotes, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var note = try? decoder.decode(Note.self, from: data),
                  !(note.body.isEmpty && note.thoughts.isEmpty),
                  !notes.contains(where: { $0.id == note.id }) else { continue }
            note.fileName = nil
            notes.append(note)
            write(note.id)
        }
    }
}
