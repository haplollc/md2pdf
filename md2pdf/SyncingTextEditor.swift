//
//  SyncingTextEditor.swift
//  md2pdf
//
//  A plain-text editor that, unlike SwiftUI's `TextEditor`, exposes its
//  scroll position: it reports which source line sits at the top of the
//  viewport and can be told to scroll a given line to the top. Those two
//  hooks are what make line-anchored editor<->preview scroll syncing
//  possible. Wraps `UITextView` (iOS) / `NSTextView` (macOS) so the
//  underlying scroll view and layout manager are reachable.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A request to scroll the editor so `line` is at the top. The `token`
/// makes repeated requests to the same line still distinct, so the editor
/// re-scrolls even when the target line doesn't change.
struct ScrollToLine: Equatable {
    var line: Int
    var token: Int
}

struct SyncingTextEditor {
    @Binding var text: String
    /// Fired (only for user-driven scrolling) with the source line now at
    /// the top of the viewport.
    var onTopLineChanged: (Int) -> Void
    /// Fired when the user starts/stops physically dragging the editor, so
    /// the owner can hold the scroll-sync lock for the whole gesture.
    var onUserScrollBegan: () -> Void = {}
    var onUserScrollEnded: () -> Void = {}
    /// When set to a new value, the editor scrolls that line to the top.
    var scrollToLine: ScrollToLine?
}

// MARK: - Line math (shared)

enum LineMath {
    /// 0-based line index containing character offset `charIndex`.
    static func line(forCharacterOffset charIndex: Int, in text: String) -> Int {
        guard charIndex > 0, !text.isEmpty else { return 0 }
        let end = text.index(text.startIndex, offsetBy: min(charIndex, text.count))
        var count = 0
        for ch in text[text.startIndex..<end] where ch == "\n" { count += 1 }
        return count
    }

    /// Character offset where 0-based `line` starts.
    static func characterOffset(ofLine line: Int, in text: String) -> Int {
        guard line > 0 else { return 0 }
        var seen = 0
        var offset = 0
        for ch in text {
            if seen == line { break }
            offset += 1
            if ch == "\n" { seen += 1 }
        }
        return offset
    }
}

#if os(macOS)
extension SyncingTextEditor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.string = text
        textView.allowsUndo = true
        scroll.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll

        // Observe scrolling via the clip view's bounds changes.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.startObserving(clipView: scroll.contentView, scrollView: scroll)

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count), length: 0))
        }
        context.coordinator.applyScrollCommandIfNeeded()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncingTextEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastScroll: ScrollToLine?
        private var isProgrammatic = false

        init(_ parent: SyncingTextEditor) { self.parent = parent }

        func startObserving(clipView: NSClipView, scrollView: NSScrollView) {
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clipView
            )
            // Live-scroll notifications give us trackpad drag begin/end so we
            // can hold the sync lock for the whole gesture.
            center.addObserver(
                self, selector: #selector(liveScrollStarted),
                name: NSScrollView.willStartLiveScrollNotification, object: scrollView
            )
            center.addObserver(
                self, selector: #selector(liveScrollEnded),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        @objc private func liveScrollStarted() { parent.onUserScrollBegan() }
        @objc private func liveScrollEnded() { parent.onUserScrollEnded() }

        @objc private func boundsChanged() {
            guard !isProgrammatic, let textView, let scrollView,
                  let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            let topY = scrollView.contentView.bounds.origin.y
            let point = CGPoint(x: 0, y: max(0, topY))
            let glyphIndex = lm.glyphIndex(for: point, in: tc)
            let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
            let line = LineMath.line(forCharacterOffset: charIndex, in: textView.string)
            // Defer to avoid re-entrant layout resetting the scroll.
            DispatchQueue.main.async { self.parent.onTopLineChanged(line) }
        }

        func applyScrollCommandIfNeeded() {
            guard let cmd = parent.scrollToLine, cmd != lastScroll else { return }
            lastScroll = cmd
            guard let textView, let scrollView,
                  let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            let charIndex = LineMath.characterOffset(ofLine: cmd.line, in: textView.string)
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 0), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            isProgrammatic = true
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: max(0, rect.minY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { self.isProgrammatic = false }
        }
    }
}

#else

extension SyncingTextEditor: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        textView.text = text
        textView.alwaysBounceVertical = true
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            let selected = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(location: min(selected.location, (text as NSString).length), length: 0)
        }
        context.coordinator.applyScrollCommandIfNeeded()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyncingTextEditor
        weak var textView: UITextView?
        var lastScroll: ScrollToLine?
        private var isProgrammatic = false

        init(_ parent: SyncingTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammatic, let textView else { return }
            let y = textView.contentOffset.y + textView.textContainerInset.top
            let point = CGPoint(x: 0, y: max(0, y))
            guard let pos = textView.closestPosition(to: point) else { return }
            let charIndex = textView.offset(from: textView.beginningOfDocument, to: pos)
            let line = LineMath.line(forCharacterOffset: charIndex, in: textView.text)
            // Defer: mutating SwiftUI state synchronously inside the scroll
            // callback re-enters layout and resets this very scroll.
            DispatchQueue.main.async { self.parent.onTopLineChanged(line) }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onUserScrollBegan()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { parent.onUserScrollEnded() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            parent.onUserScrollEnded()
        }

        func applyScrollCommandIfNeeded() {
            guard let cmd = parent.scrollToLine, cmd != lastScroll, let textView else { return }
            lastScroll = cmd
            let charIndex = LineMath.characterOffset(ofLine: cmd.line, in: textView.text)
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: charIndex, length: 0), actualCharacterRange: nil
            )
            let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
            let maxY = max(0, textView.contentSize.height - textView.bounds.height + textView.textContainerInset.bottom)
            let targetY = min(max(0, rect.minY - textView.textContainerInset.top), maxY)
            isProgrammatic = true
            textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            DispatchQueue.main.async { self.isProgrammatic = false }
        }
    }
}
#endif
