import AppKit
import Observation
import SwiftUI

struct Anchor: Equatable {
    let id: UUID
    let quote: String
}

/// Shared between the AppKit editor and the SwiftUI margins.
@MainActor
@Observable
final class MarginLayoutModel {
    /// Top of each anchored quote, in document coordinates.
    var positions: [UUID: CGFloat] = [:]
    /// False when the window is too narrow for two margins; everything then goes on the right.
    var isDual = true
    /// Bottom of the lowest card in each margin; the page grows to fit them.
    var bottoms: [MarginSide: CGFloat] = [:] {
        didSet { if bottoms != oldValue { onContentBottomChange?(contentBottom) } }
    }
    var contentBottom: CGFloat { bottoms.values.max() ?? 0 }
    @ObservationIgnored var onContentBottomChange: ((CGFloat) -> Void)?

    /// Which margin a thought shows in right now.
    func column(for side: MarginSide) -> MarginSide { isDual ? side : .right }
}

/// The page: a centered text column with a margin on each side. Both margins live inside the
/// text view, so margin notes scroll with the words they sit beside.
/// The page itself only ever holds the writer's plain text.
final class NotebookTextView: NSTextView {
    static let gap: CGFloat = 32
    static let sidePad: CGFloat = 24
    static let topPad: CGFloat = 36
    static let maxTextWidth: CGFloat = 640
    static let minTextWidth: CGFloat = 420
    static let minMargin: CGFloat = 200
    static let maxMargin: CGFloat = 270

    var leftHost: NSView?
    var rightHost: NSView?
    var placeholder = ""
    var fontSize: CGFloat = 17
    /// When true, ⌘Return sends a highlight and plain Return types normally.
    var sendWithCommand = false
    var onSubmit: ((NSRange) -> Void)?
    var onClick: (() -> Void)?
    var onColumnsChanged: ((Bool) -> Void)?
    private(set) var textX: CGFloat = sidePad
    private(set) var textWidth: CGFloat = maxTextWidth
    private(set) var isDual = true

    override var textContainerOrigin: NSPoint { NSPoint(x: textX, y: Self.topPad) }

    // Plain text only: no images, files or rich text can be pasted or dropped onto the page.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutColumns()
    }

    func relayoutColumns() {
        let w = bounds.width
        let dual = w >= 2 * Self.sidePad + 2 * Self.gap + 2 * Self.minMargin + Self.minTextWidth
        let margin: CGFloat
        let textW: CGFloat
        let x: CGFloat
        if dual {
            margin = min(Self.maxMargin, max(Self.minMargin, (w - 2 * Self.sidePad - 2 * Self.gap - Self.maxTextWidth) / 2))
            textW = min(Self.maxTextWidth, w - 2 * Self.sidePad - 2 * Self.gap - 2 * margin)
            let group = 2 * margin + 2 * Self.gap + textW
            x = floor((w - group) / 2) + margin + Self.gap
        } else {
            margin = 230
            textW = max(240, min(Self.maxTextWidth, w - 2 * Self.sidePad - Self.gap - margin))
            let group = textW + Self.gap + margin
            x = max(Self.sidePad, floor((w - group) / 2))
        }

        var changed = dual != isDual
        if x != textX { textX = x; changed = true }
        if let container = textContainer, container.size.width != textW {
            container.size = NSSize(width: textW, height: CGFloat.greatestFiniteMagnitude)
            changed = true
        }
        textWidth = textW
        isDual = dual

        leftHost?.isHidden = !dual
        leftHost?.frame = NSRect(x: x - Self.gap - margin, y: 0, width: margin, height: bounds.height)
        rightHost?.frame = NSRect(x: x + textW + Self.gap, y: 0, width: margin, height: bounds.height)
        if changed {
            needsDisplay = true
            onColumnsChanged?(dual)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick?()
    }

    /// Return (or ⌘Return, per Settings) with text highlighted sends it instead of replacing it.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let wanted: NSEvent.ModifierFlags = sendWithCommand ? [.command] : []
        let r = selectedRange()
        if isReturn, mods == wanted, r.length > 0, !hasMarkedText() {
            onSubmit?(r)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.ruleNS.setFill()
        if isDual {
            NSRect(x: textX - Self.gap / 2, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        NSRect(x: textX + textWidth + Self.gap / 2, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard string.isEmpty, !placeholder.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(size: fontSize), .foregroundColor: Theme.placeholderNS,
            .paragraphStyle: Theme.bodyParagraph(),
        ]
        NSAttributedString(string: placeholder, attributes: attrs)
            .draw(in: NSRect(x: textX + pad, y: Self.topPad, width: textWidth - 2 * pad, height: 200))
    }
}

struct NoteTextEditor<Margin: View>: NSViewRepresentable {
    @Binding var text: String
    var anchors: [Anchor]
    /// Thoughts whose words are lit up on the page (the open or hovered one). Nothing else is drawn on the page.
    var highlighted: Set<UUID>
    var layout: MarginLayoutModel
    var placeholder: String
    var fontSize: CGFloat
    var sendWithCommand: Bool
    var onTextClick: () -> Void
    /// Send key pressed while text is highlighted: the range and the top of its first line.
    var onSubmitSelection: (NSRange, CGFloat) -> Void
    var margin: (MarginSide) -> Margin

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        manager.addTextContainer(container)

        let tv = NotebookTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 0, height: NotebookTextView.topPad)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.insertionPointColor = Theme.textNS
        tv.fontSize = fontSize
        tv.sendWithCommand = sendWithCommand
        tv.typingAttributes = Theme.bodyAttributes(size: fontSize)
        tv.defaultParagraphStyle = Theme.bodyParagraph()
        tv.placeholder = placeholder
        tv.string = text
        storage.setAttributes(Theme.bodyAttributes(size: fontSize), range: NSRange(location: 0, length: storage.length))
        tv.delegate = context.coordinator

        let left = NSHostingView(rootView: AnyView(margin(.left)))
        let right = NSHostingView(rootView: AnyView(margin(.right)))
        for host in [left, right] {
            host.sizingOptions = []
            tv.addSubview(host)
        }
        tv.leftHost = left
        tv.rightHost = right

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = tv

        let c = context.coordinator
        c.textView = tv
        c.scrollView = scroll
        c.leftHost = left
        c.rightHost = right
        tv.onClick = { [weak c] in c?.parent.onTextClick() }
        tv.onSubmit = { [weak c] range in c?.submit(range) }
        tv.onColumnsChanged = { [weak c] dual in
            guard let c else { return }
            if c.parent.layout.isDual != dual { c.parent.layout.isDual = dual }
            c.layoutChanged()
        }
        layout.onContentBottomChange = { [weak c] _ in c?.updatePageHeight() }

        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            c, selector: #selector(Coordinator.viewportChanged),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)

        DispatchQueue.main.async {
            c.updatePageHeight()
            c.applyHighlights()
            c.layoutChanged()
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.leftHost?.rootView = AnyView(margin(.left))
        c.rightHost?.rootView = AnyView(margin(.right))
        guard let tv = c.textView else { return }
        tv.sendWithCommand = sendWithCommand
        tv.placeholder = placeholder
        if tv.string != text || tv.fontSize != fontSize {
            if tv.string != text { tv.string = text }
            tv.fontSize = fontSize
            tv.typingAttributes = Theme.bodyAttributes(size: fontSize)
            tv.textStorage?.setAttributes(Theme.bodyAttributes(size: fontSize),
                                          range: NSRange(location: 0, length: (tv.string as NSString).length))
            c.applyHighlights()
            c.layoutChanged()
            tv.needsDisplay = true
        }
        if c.lastAnchors != anchors || c.lastHighlighted != highlighted {
            c.lastAnchors = anchors
            c.lastHighlighted = highlighted
            c.applyHighlights()
            c.layoutChanged()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor
        weak var textView: NotebookTextView?
        weak var scrollView: NSScrollView?
        weak var leftHost: NSHostingView<AnyView>?
        weak var rightHost: NSHostingView<AnyView>?
        var lastAnchors: [Anchor] = []
        var lastHighlighted: Set<UUID> = []
        private var ranges: [UUID: NSRange] = [:]
        private var layoutScheduled = false

        init(_ parent: NoteTextEditor) { self.parent = parent }

        // MARK: Delegate

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            applyHighlights()
            layoutChanged()
        }

        /// Sends a highlighted range, then drops the highlight so the next keystroke can't overwrite it.
        func submit(_ r: NSRange) {
            guard let tv = textView else { return }
            let y = lineTop(for: NSRange(location: r.location, length: 0))
            tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
            parent.onSubmitSelection(r, y)
        }

        // MARK: Anchors

        func applyHighlights() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            var found: [UUID: NSRange] = [:]
            for a in parent.anchors where !a.quote.isEmpty {
                let r = ns.range(of: a.quote)
                if r.location != NSNotFound { found[a.id] = r }
            }
            ranges = found

            // A display-only tint while a note is open or hovered. Never stored in the note.
            let full = NSRange(location: 0, length: ns.length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for id in parent.highlighted {
                guard let r = found[id] else { continue }
                lm.addTemporaryAttributes([.backgroundColor: Theme.highlightNS], forCharacterRange: r)
            }
        }

        /// Recomputes where each anchor sits, after layout settles.
        func layoutChanged() {
            guard !layoutScheduled else { return }
            layoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutScheduled = false
                self.reportPositions()
            }
        }

        private func reportPositions() {
            var positions: [UUID: CGFloat] = [:]
            for (id, r) in ranges { positions[id] = lineTop(for: r) }
            if positions != parent.layout.positions { parent.layout.positions = positions }
        }

        private func lineTop(for range: NSRange) -> CGFloat {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return 0 }
            lm.ensureLayout(for: container)
            let length = (tv.string as NSString).length
            if length == 0 { return tv.textContainerOrigin.y }
            let safe = NSRange(location: min(range.location, max(0, length - 1)), length: max(1, range.length))
            let glyphs = lm.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
            return rect.minY + tv.textContainerOrigin.y
        }

        // MARK: Page height

        @objc func viewportChanged() { updatePageHeight() }

        /// Keeps the page at least as tall as the window and the lowest margin card.
        func updatePageHeight() {
            guard let tv = textView, let scroll = scrollView else { return }
            let needed = max(scroll.contentSize.height, parent.layout.contentBottom + 80)
            if abs(tv.minSize.height - needed) > 0.5 {
                tv.minSize = NSSize(width: 0, height: needed)
                tv.sizeToFit()
            }
        }
    }
}
