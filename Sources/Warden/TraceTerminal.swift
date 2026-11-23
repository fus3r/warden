import AppKit
import SwiftUI
import WardenCore

/// A read-only terminal for one agent. New events are appended in place, so a selection and the reading position
/// survive updates, and new replies type in while the terminal follows its output.
@MainActor
struct TraceTerminal: NSViewRepresentable {
    /// Nil until the log has been read once.
    let events: [TraceEvent]?
    let style: TranscriptRenderer.Style
    let follows: Bool
    let types: Bool
    /// Changes when the viewer asks to jump to the newest output.
    let jump: Int
    let label: String
    @Binding var pinned: Bool
    /// The height of the row the top edge cuts while following, for the pane to cover.
    @Binding var cover: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(style: style) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = NSScroller.preferredScrollerStyle != .overlay
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        if let text = scroll.documentView as? NSTextView {
            text.drawsBackground = false
            text.isEditable = false
            text.isSelectable = true
            text.isAutomaticLinkDetectionEnabled = false
            // A read-only log needs no text checking. Left on, the first update starts the system spelling service.
            text.enabledTextCheckingTypes = 0
            text.isContinuousSpellCheckingEnabled = false
            text.isGrammarCheckingEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticDataDetectionEnabled = false
            text.isAutomaticTextCompletionEnabled = false
            text.textContainerInset = NSSize(width: 8, height: 6)
            text.textContainer?.lineFragmentPadding = 2
            text.font = TracePalette.font
            text.linkTextAttributes = [
                .foregroundColor: TracePalette.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ]
            text.usesFindBar = true
            text.isIncrementalSearchingEnabled = true
            text.delegate = context.coordinator
        }
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let binding = $pinned
        coordinator.reportPinned = { binding.wrappedValue = $0 }
        let coverBinding = $cover
        coordinator.reportCover = { coverBinding.wrappedValue = $0 }
        let resumes = follows && !coordinator.follows
        coordinator.follows = follows
        coordinator.update(events, style: style, types: types, label: label)
        if resumes { coordinator.scrollToEnd() }
        if jump != coordinator.jump {
            coordinator.jump = jump
            coordinator.scrollToEnd()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let renderer: TranscriptRenderer
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var viewport = NSSize.zero
        private var shown: [TraceEvent] = []
        /// The UTF-16 length of each shown event's rendering, in order.
        private var lengths: [Int] = []
        private var rendered = false
        private var typing: Task<Void, Never>?
        private var typingText: NSAttributedString?
        private var typed = 0
        private var cursorShown = false
        /// The line break that ends the last event, kept out of the text so no empty line sits above the status line.
        private var trailing: NSAttributedString?
        private var pendingTrailing: NSAttributedString?
        private var coverHeight: CGFloat = 0
        private var isPinned = true
        var follows = true
        var jump = 0
        var reportPinned: ((Bool) -> Void)?
        var reportCover: ((CGFloat) -> Void)?

        init(style: TranscriptRenderer.Style) {
            renderer = TranscriptRenderer(style: style)
        }

        private var textView: NSTextView? { scroll?.documentView as? NSTextView }

        func attach(_ scroll: NSScrollView) {
            self.scroll = scroll
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                // Text reflows when a pane is resized or laid out late. A terminal that follows its output stays on its
                // last line, as Terminal does.
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.documentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isPinned, self.follows else { return }
                        self.scrollToEnd()
                    }
                }
            ]
        }

        func detach() {
            typing?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        func update(_ events: [TraceEvent]?, style: TranscriptRenderer.Style, types: Bool, label: String) {
            guard let storage = textView?.textStorage else { return }
            textView?.setAccessibilityLabel(label)
            guard let events else { return }
            if !rendered || style != renderer.style {
                finishTyping()
                restoreTrailing(storage)
                renderer.restyle(style)
                replace(from: 0, with: events, in: storage)
                trimTrailing(storage)
                rendered = true
                scrollToEnd()
                return
            }
            guard events != shown else { return }
            finishTyping()
            restoreTrailing(storage)
            let wasPinned = isPinned
            removeDropped(keeping: events, in: storage)
            let common = zip(shown, events).prefix { $0 == $1 }.count
            if common == shown.count {
                let added = events[common...].map(renderer.rendered)
                let addition = NSMutableAttributedString()
                added.forEach(addition.append)
                lengths += added.map(\.length)
                shown = events
                if types, follows, wasPinned, addition.length > 0, events[common...].contains(where: { $0.kind == .message }) {
                    type(addition)
                } else {
                    storage.append(addition)
                    trimTrailing(storage)
                    if follows, wasPinned { scrollToEnd() }
                }
            } else {
                replace(from: common, with: events, in: storage)
                trimTrailing(storage)
                if follows, wasPinned { scrollToEnd() }
            }
            renderer.keep(only: events)
        }

        /// Puts the last event's line break back before an edit, so the text matches the renderings exactly.
        private func restoreTrailing(_ storage: NSTextStorage) {
            guard let trailing else { return }
            storage.append(trailing)
            self.trailing = nil
        }

        private func trimTrailing(_ storage: NSTextStorage) {
            guard trailing == nil, storage.length > 0, (storage.string as NSString).character(at: storage.length - 1) == 10 else { return }
            let range = NSRange(location: storage.length - 1, length: 1)
            trailing = storage.attributedSubstring(from: range)
            storage.deleteCharacters(in: range)
        }

        /// The reader forgets its oldest messages and commands as new ones arrive. Deleting just those keeps a busy
        /// terminal from redrawing its whole history for every new command.
        private func removeDropped(keeping events: [TraceEvent], in storage: NSTextStorage) {
            let current = Set(events.map(\.id))
            guard shown.contains(where: { !current.contains($0.id) }) else { return }
            var location = 0
            var dropped: [NSRange] = []
            var kept: [(TraceEvent, Int)] = []
            for (event, length) in zip(shown, lengths) {
                if current.contains(event.id) {
                    kept.append((event, length))
                } else {
                    dropped.append(NSRange(location: location, length: length))
                }
                location += length
            }
            storage.beginEditing()
            for range in dropped.reversed() where NSMaxRange(range) <= storage.length {
                storage.deleteCharacters(in: range)
            }
            storage.endEditing()
            shown = kept.map(\.0)
            lengths = kept.map(\.1)
        }

        private func replace(from index: Int, with events: [TraceEvent], in storage: NSTextStorage) {
            let start = min(storage.length, lengths.prefix(index).reduce(0, +))
            let pieces = events[index...].map(renderer.rendered)
            let tail = NSMutableAttributedString()
            pieces.forEach(tail.append)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            storage.endEditing()
            lengths = Array(lengths.prefix(index)) + pieces.map(\.length)
            shown = events
        }

        func scrollToEnd() {
            textView?.scrollToEndOfDocument(nil)
            updateCover()
        }

        private func scrolled() {
            guard let scroll, let document = scroll.documentView else { return }
            if scroll.contentView.bounds.size != viewport {
                // A resize, not the viewer scrolling.
                viewport = scroll.contentView.bounds.size
                if isPinned, follows { scrollToEnd() } else { updateCover() }
                return
            }
            let pinned = scroll.contentView.bounds.maxY >= document.frame.maxY - 14
            guard pinned != isPinned else { return }
            isPinned = pinned
            updateCover()
            // Following output scrolls every pane often. Overlay scrollers appear only once the viewer scrolls back.
            if NSScroller.preferredScrollerStyle == .overlay { scroll.hasVerticalScroller = !pinned }
            let report = reportPinned
            DispatchQueue.main.async { report?(pinned) }
        }

        /// Terminal never shows half a row while it follows output. The row cut by the top edge is covered until it
        /// scrolls out, so the first visible line is whole and the last one stays just above the status line.
        private func updateCover() {
            guard let scroll, let text = textView else { return }
            var height: CGFloat = 0
            let top = scroll.contentView.bounds.minY
            if isPinned, follows, top > 0, let line = lineBounds(at: top, in: text), line.lowerBound < top {
                // Commas and parentheses hang a little below the line's typographic bounds.
                height = ceil(line.upperBound - top) + 2
            }
            guard height != coverHeight else { return }
            coverHeight = height
            let report = reportCover
            DispatchQueue.main.async { report?(height) }
        }

        /// The top and bottom of the laid-out line at a height in the text view.
        private func lineBounds(at y: CGFloat, in text: NSTextView) -> ClosedRange<CGFloat>? {
            let origin = text.textContainerOrigin
            let point = CGPoint(x: 1, y: y - origin.y)
            if let manager = text.textLayoutManager {
                guard let fragment = manager.textLayoutFragment(for: point) else { return nil }
                let frame = fragment.layoutFragmentFrame
                for line in fragment.textLineFragments {
                    let top = frame.minY + line.typographicBounds.minY + origin.y
                    let bottom = frame.minY + line.typographicBounds.maxY + origin.y
                    if top <= y, y < bottom { return top...bottom }
                }
                return nil
            }
            guard let manager = text.layoutManager, let container = text.textContainer else { return nil }
            let glyph = manager.glyphIndex(for: point, in: container)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: origin.y)
            return rect.minY <= y && y < rect.maxY ? rect.minY...rect.maxY : nil
        }

        // MARK: Typing

        /// Types a new reply in about a second, behind a block cursor, as a command-line agent streams it.
        private func type(_ addition: NSAttributedString) {
            guard let storage = textView?.textStorage else { return }
            var text = addition
            if text.length > 1, (text.string as NSString).character(at: text.length - 1) == 10 {
                pendingTrailing = text.attributedSubstring(from: NSRange(location: text.length - 1, length: 1))
                text = text.attributedSubstring(from: NSRange(location: 0, length: text.length - 1))
            }
            typingText = text
            typed = 0
            let steps = min(44, max(8, text.length / 6))
            let batch = max(1, Int((Double(text.length) / Double(steps)).rounded(.up)))
            showCursor(in: storage, after: text.attributes(at: 0, effectiveRange: nil))
            typing = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(24))
                    guard let self, !Task.isCancelled else { return }
                    if !self.step(batch) { break }
                }
                self?.finishTyping()
            }
        }

        /// Types the next characters. False once the reply is complete.
        private func step(_ batch: Int) -> Bool {
            guard let source = typingText, let storage = textView?.textStorage, typed < source.length else { return false }
            let string = source.string as NSString
            var end = min(source.length, typed + batch)
            if end < source.length { end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: end - 1)) }
            let piece = source.attributedSubstring(from: NSRange(location: typed, length: end - typed))
            storage.beginEditing()
            hideCursor(in: storage)
            storage.append(piece)
            showCursor(in: storage, after: piece.attributes(at: max(0, piece.length - 1), effectiveRange: nil))
            storage.endEditing()
            typed = end
            if follows, isPinned { scrollToEnd() }
            return typed < source.length
        }

        /// Shows the rest of a reply at once, as when new output arrives during typing.
        private func finishTyping() {
            typing?.cancel()
            typing = nil
            guard let source = typingText, let storage = textView?.textStorage else {
                typingText = nil
                return
            }
            storage.beginEditing()
            hideCursor(in: storage)
            if typed < source.length {
                storage.append(source.attributedSubstring(from: NSRange(location: typed, length: source.length - typed)))
            }
            storage.endEditing()
            typingText = nil
            typed = 0
            if let pendingTrailing {
                trailing = pendingTrailing
                self.pendingTrailing = nil
            }
            if follows, isPinned { scrollToEnd() }
        }

        private func showCursor(in storage: NSTextStorage, after attributes: [NSAttributedString.Key: Any]) {
            var cursor = attributes
            cursor[.foregroundColor] = TracePalette.cursor
            cursor[.font] = TracePalette.font
            cursor.removeValue(forKey: .link)
            storage.append(NSAttributedString(string: "▌", attributes: cursor))
            cursorShown = true
        }

        private func hideCursor(in storage: NSTextStorage) {
            guard cursorShown, storage.length > 0 else { return }
            storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
            cursorShown = false
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            TranscriptLinks.open(url)
            return true
        }
    }
}
