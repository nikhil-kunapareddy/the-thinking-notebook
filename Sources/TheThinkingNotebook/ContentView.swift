import SwiftUI

struct ContentView: View {
    @Environment(NoteStore.self) private var store
    @ViewState private var pendingDelete: UUID?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.sortedNotes) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button("Delete Note…", role: .destructive) { pendingDelete = note.id }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Settings (⌘,)")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onDeleteCommand { pendingDelete = store.selection }
            .toolbar {
                ToolbarItem {
                    Button { store.createNote() } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .help("New note (⌘N)")
                }
            }
        } detail: {
            if let id = store.selection, store.note(id) != nil {
                NoteView(noteID: id, store: store).id(id)
            } else {
                VStack(spacing: 12) {
                    Text("Nothing open").font(.title3).foregroundStyle(.secondary)
                    Button("Start writing") { store.createNote() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.paper)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { id in
            Button("Delete", role: .destructive) { store.delete(id) }
        } message: { id in
            Text("“\(store.note(id)?.title ?? "Untitled")” and its margin notes will be moved to the Trash.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flush()
        }
        // Pick up edits made to the .md files in other apps.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reloadFromDisk()
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.system(.body, design: .serif))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                let count = note.openThoughts.count
                if count > 0 {
                    Text("·")
                    Text(count == 1 ? "1 thought" : "\(count) thoughts")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
