import SwiftUI

struct NoteView: View {
    @Environment(NoteStore.self) private var store
    let noteID: UUID

    @ViewState private var brain: NoteBrain
    @ViewState private var layout = MarginLayoutModel()
    @ViewState private var activeID: UUID?
    @ViewState private var hoverID: UUID?
    @AppStorage(Prefs.pageFontSize) private var pageSize = 17.0
    @AppStorage(Prefs.sendKey) private var sendKey = "return"

    init(noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        _brain = State(initialValue: NoteBrain(noteID: noteID, store: store))
    }

    var body: some View {
        if let note = store.note(noteID) {
            editor(note)
                .background(Theme.paper)
                .navigationTitle(note.title)
                .overlay(alignment: .bottom) { errorBanner }
        }
    }

    private func editor(_ note: Note) -> some View {
        NoteTextEditor(
            text: Binding(
                get: { store.note(noteID)?.body ?? "" },
                set: { newValue in store.update(noteID) { $0.body = newValue } }),
            anchors: note.openThoughts.map { Anchor(id: $0.id, quote: $0.quote) },
            highlighted: Set([activeID, hoverID].compactMap { $0 }),
            layout: layout,
            placeholder: "Start writing. Highlight any part and press \(sendKey == "commandReturn" ? "⌘Return" : "Return") to get a note in the margin.",
            fontSize: CGFloat(pageSize).clamped(12, 28),
            sendWithCommand: sendKey == "commandReturn",
            onTextClick: { if activeID != nil { activeID = nil } },
            onSubmitSelection: { range, y in
                activeID = nil
                brain.look(at: range, y: y)
            },
            margin: { side in
                MarginView(
                    side: side, note: note, brain: brain, layout: layout,
                    activeID: $activeID, hoverID: $hoverID)
            }
        )
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = brain.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { brain.error = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
