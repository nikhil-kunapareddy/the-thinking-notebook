import SwiftUI

// MARK: - Layout

private struct DesiredY: LayoutValueKey { static let defaultValue: CGFloat = 0 }
private struct IsPinned: LayoutValueKey { static let defaultValue = false }

/// Places each card beside its anchor. The pinned (active) card sits exactly on its anchor;
/// the others slide up or down just enough not to overlap, like comments in a document.
private struct MarginStack: Layout {
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? NotebookTextView.minMargin, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let width = bounds.width
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let desired = subviews.map { $0[DesiredY.self] }
        var ys = desired

        if let a = subviews.indices.first(where: { subviews[$0][IsPinned.self] }) {
            var bottom = ys[a] + heights[a]
            for i in stride(from: a + 1, to: n, by: 1) {
                ys[i] = max(desired[i], bottom + spacing)
                bottom = ys[i] + heights[i]
            }
            var top = ys[a]
            for i in stride(from: a - 1, through: 0, by: -1) {
                ys[i] = min(desired[i], top - spacing - heights[i])
                top = ys[i]
            }
            let minTop = NotebookTextView.topPad - 8
            if ys[0] < minTop {
                let shift = minTop - ys[0]
                for i in 0..<n { ys[i] += shift }
            }
        } else {
            var bottom = -CGFloat.infinity
            for i in 0..<n {
                ys[i] = max(desired[i], bottom + spacing)
                bottom = ys[i] + heights[i]
            }
        }

        for i in 0..<n {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY + ys[i]),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: heights[i]))
        }
    }
}

private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Margin

/// One of the two margins. Claude only ever writes here, never on the page.
struct MarginView: View {
    let side: MarginSide
    let note: Note
    let brain: NoteBrain
    let layout: MarginLayoutModel
    @Binding var activeID: UUID?
    @Binding var hoverID: UUID?

    private enum Item: Identifiable {
        case pending(PendingPass)
        case thought(Thought)
        var id: String {
            switch self {
            case .pending(let p): return p.id.uuidString
            case .thought(let t): return t.id.uuidString
            }
        }
    }

    /// Cards have top padding; shifting them up lines their first line up with the anchor.
    private let cardInset: CGFloat = 10

    private var items: [(item: Item, y: CGFloat)] {
        var list: [(Item, CGFloat)] = note.openThoughts
            .filter { layout.column(for: $0.resolvedSide) == side }
            .map { t in (.thought(t), (layout.positions[t.id] ?? NotebookTextView.topPad) - cardInset) }
        for p in brain.pending where layout.column(for: p.side) == side {
            list.append((.pending(p), p.y - cardInset))
        }
        return list.sorted { $0.1 < $1.1 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarginStack {
                ForEach(items, id: \.item.id) { entry in
                    card(for: entry.item)
                        .layoutValue(key: DesiredY.self, value: entry.y)
                        .layoutValue(key: IsPinned.self, value: isPinned(entry.item))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("margin")).maxY)
                        })
                        .transition(.opacity.combined(with: .offset(x: side == .right ? 12 : -12)))
                }
            }
        }
        .coordinateSpace(name: "margin")
        .onPreferenceChange(BottomKey.self) { layout.bottoms[side] = $0 }
        .animation(.snappy(duration: 0.28), value: activeID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isPinned(_ item: Item) -> Bool {
        switch item {
        case .pending: return false
        case .thought(let t): return t.id == activeID
        }
    }

    @ViewBuilder
    private func card(for item: Item) -> some View {
        switch item {
        case .pending:
            // Claude is looking at the highlighted passage.
            ThinkingDots()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought(let t):
            ThoughtCard(
                thought: t,
                isActive: t.id == activeID,
                isUnanchored: !t.quote.isEmpty && layout.positions[t.id] == nil,
                streaming: brain.streaming[t.id],
                side: side,
                canMove: layout.isDual,
                onActivate: { activeID = t.id },
                onHover: { inside in
                    if inside { hoverID = t.id } else if hoverID == t.id { hoverID = nil }
                },
                onMove: { brain.move(t.id, to: side == .left ? .right : .left) },
                onClose: { activeID = nil },
                onDismiss: {
                    if activeID == t.id { activeID = nil }
                    brain.dismiss(t.id)
                },
                onReply: { brain.reply(to: t.id, $0) })
        }
    }
}

// MARK: - Cards

struct ThoughtCard: View {
    let thought: Thought
    let isActive: Bool
    let isUnanchored: Bool
    let streaming: String?
    let side: MarginSide
    let canMove: Bool
    var onActivate: () -> Void
    var onHover: (Bool) -> Void
    var onMove: () -> Void
    var onClose: () -> Void
    var onDismiss: () -> Void
    var onReply: (String) -> Void

    @ViewState private var draft = ""
    @ViewState private var hovering = false
    @AppStorage(Prefs.marginFontSize) private var marginSize = 14.0
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isActive {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(header)
                        .font(.caption.italic())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    iconButton("chevron.up", help: "Collapse (Esc)", action: onClose)
                    iconButton("xmark", help: "Dismiss this thought", action: onDismiss)
                }
                .padding(.top, -4)
                .padding(.trailing, -6)
            } else if isUnanchored || thought.quote.isEmpty {
                Text(header)
                    .font(.caption.italic())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }

            if isActive {
                ForEach(thought.messages) { message in
                    MessageText(message: message, selectable: true)
                }
                if let streaming {
                    Group {
                        if streaming.isEmpty {
                            ThinkingDots()
                        } else {
                            Text(streaming)
                                .font(Theme.inkFont(marginSize))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                replyField
            } else {
                collapsed
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Theme.card : (hovering ? Theme.card.opacity(0.6) : .clear))
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 8, y: 2)
        }
        // The ink bar sits on the edge nearest the page.
        .overlay(alignment: side == .right ? .leading : .trailing) {
            if !isActive {
                Capsule().fill(Theme.ink.opacity(0.3)).frame(width: 2).padding(.vertical, 10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering && !isActive {
                iconButton("xmark", help: "Dismiss this thought", action: onDismiss).padding(4)
            }
        }
        .contentShape(Rectangle())
        // Only while collapsed: an always-on tap gesture would swallow clicks meant for the reply field.
        .gesture(TapGesture().onEnded { open() }, including: isActive ? .subviews : .all)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .onExitCommand { onClose() }
        .contextMenu {
            if canMove {
                Button(side == .right ? "Move to Left Margin" : "Move to Right Margin", action: onMove)
            }
            Button("Dismiss", action: onDismiss)
        }
        .onChange(of: isActive) { _, active in if !active { replyFocused = false } }
    }

    private var header: String {
        if thought.quote.isEmpty { return "On the whole note" }
        return isUnanchored ? "“\(thought.quote)” (no longer in the note)" : "“\(thought.quote)”"
    }

    private func open() {
        onActivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { replyFocused = true }
    }

    @ViewBuilder
    private var collapsed: some View {
        let first = thought.messages.first
        if let first {
            MessageText(message: first)
                .lineLimit(first.role == .writer ? 2 : 6)
                .padding(.trailing, 14)
        }
        if first?.role == .writer, let answer = thought.messages.dropFirst().first {
            MessageText(message: answer).lineLimit(4)
        } else if streaming != nil {
            ThinkingDots()
        }
        let more = thought.messages.count - (first?.role == .writer ? 2 : 1)
        if more > 0 {
            Text(more == 1 ? "1 more reply" : "\(more) more replies")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Push back, ask why…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.writerFont(size: 13))
                .lineLimit(1...6)
                .focused($replyFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(canSend ? Theme.ink : Theme.muted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
    }

    private var canSend: Bool {
        streaming == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        onReply(draft)
        draft = ""
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MessageText: View {
    let message: ThreadMessage
    var selectable = false
    @AppStorage(Prefs.marginFontSize) private var marginSize = 14.0

    var body: some View {
        if selectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .thinker:
            Text(message.text)
                .font(Theme.inkFont(marginSize))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .writer:
            Text(message.text)
                .font(Theme.writerFont(size: marginSize - 1))
                .foregroundStyle(Theme.text.opacity(0.85))
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.text.opacity(0.25)).frame(width: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ThinkingDots: View {
    @ViewState private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 0.9 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }
        .padding(.vertical, 4)
        .onAppear { on = true }
    }
}
