//
//  ViewModels.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import AppKit
import MarkdownUI
import UniformTypeIdentifiers
import PDFKit

class HomeViewModel: ObservableObject {
    @Published var markdownContent: String = ""
}

class EditorViewModel: ObservableObject {
    struct Constants {
        static let pdfPageWidth:  CGFloat = 595
        static let pdfPageHeight: CGFloat = 842
        static let margin: CGFloat = 50
        /// Preferred (and maximum) scale: every page that fits naturally at
        /// this scale renders here. Sets the "default" text size on paper —
        /// 0.82 puts docC's 13pt body around 10.7pt.
        static let viewScale: CGFloat = 0.82
        /// Minimum acceptable scale for a single page. Pages that *almost*
        /// fit another block at preferred scale are allowed to shrink down
        /// to this scale so the extra block can be included. Below this, we
        /// stop trying and start a new page (text would become too small).
        /// 0.70 puts body type around 9pt — still legible.
        static let minViewScale: CGFloat = 0.70
    }

    @Published var markdownContent: String = ""

    @MainActor
    func saveAsPDF() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Rendered Markdown as PDF"
        savePanel.nameFieldStringValue = "Markdown.pdf"
        savePanel.allowedContentTypes = [.pdf]

        if savePanel.runModal() == .OK, let saveURL = savePanel.url {
            Task { await generatePDF(to: saveURL) }
        }
    }

    @MainActor
    func generatePDF(to url: URL) async {
        let pageSize = CGSize(width: Constants.pdfPageWidth, height: Constants.pdfPageHeight)
        let margin = Constants.margin
        let pdfContentWidth = pageSize.width - 2 * margin
        let pdfContentHeight = pageSize.height - 2 * margin

        // Render the SwiftUI view at a *wider* logical width than the PDF page,
        // then shrink the captured bitmap when drawing — so text, spacing, and
        // images all scale down uniformly on the page. Without this the docC
        // 13pt body type looks oversized on an A4 column. See `viewScale`.
        let preferredScale = Constants.viewScale
        let minScale = Constants.minViewScale
        let viewWidth = pdfContentWidth / preferredScale
        // Hard page limit: we allow the packer to keep adding blocks until
        // the page can no longer fit at any scale ≥ minScale. Pages whose
        // content exceeds the preferred scale's natural page height will
        // render at a per-page scale that shrinks them to fit the paper.
        let maxPageHeight = pdfContentHeight / minScale

        // Source-level transforms (footnotes, math, …) — see MarkdownPreprocessor.
        // Doing this before image scanning + block splitting means downstream
        // stages see the expanded markdown.
        let processedMarkdown = MarkdownPreprocessor.process(markdownContent)

        // Eagerly download any remote images referenced in the markdown so the
        // renderer can hand them to MarkdownUI synchronously. `AsyncImage`-style
        // loading doesn't work during a static PDF render — by the time the
        // load completes, we've already snapshotted the view.
        let imageCache = await Self.preloadRemoteImages(in: processedMarkdown)

        // === BLOCK-LEVEL PAGINATION ===
        //
        // Earlier we rendered the whole document into one tall bitmap and tried
        // to find horizontal whitespace bands to slice on. That's heuristic and
        // fails on dense content: anti-aliasing fills line gaps with enough
        // pixels that the "blank row" detector misses real line boundaries, so
        // we end up slicing through glyphs or images.
        //
        // The reliable approach is to do pagination *at the markdown source
        // level*. We split the source into block-level chunks (paragraphs,
        // tables, lists, images, code blocks, …), measure each chunk's
        // rendered height when placed alone in a MarkdownUI view, then greedily
        // pack chunks onto pages so the next chunk wouldn't overflow the page.
        // Each page is then rendered as its OWN Markdown view — a complete,
        // self-contained MarkdownUI render. There's no slicing across blocks,
        // so glyphs and images are inherently safe.

        let blocks = Self.splitMarkdownIntoBlocks(processedMarkdown)
        guard !blocks.isEmpty else {
            // Empty doc → produce a single blank page so callers always get a
            // valid PDF.
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            if let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) {
                ctx.beginPDFPage(nil)
                ctx.endPDFPage()
                ctx.closePDF()
            }
            return
        }

        // A single offscreen window is reused across every measurement and
        // every page render. Recreating the window per call corrupts AppKit's
        // internal state and produces blank snapshots after a few iterations.
        let offscreenWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: viewWidth, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isReleasedWhenClosed = false
        defer {
            offscreenWindow.contentView = nil
            offscreenWindow.close()
        }

        // Helper: build a Markdown view configured the same way for measure & render.
        let makeMarkdownView: (String) -> AnyView = { md in
            AnyView(
                Markdown(md)
                    .markdownTheme(.docC)
                    .markdownImageProvider(PreloadedImageProvider(cache: imageCache))
                    .frame(width: viewWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
            )
        }

        // Helper: render the given list of block indices into a hosting view,
        // returning the view (sized to its rendered content) and the rendered
        // height. We measure the *actual combined render* — not the sum of
        // per-block measurements — because MarkdownUI applies block spacing
        // that can't be derived from individual block heights alone.
        func renderPage(blockIndices: [Int]) -> (hosting: NSHostingView<AnyView>, height: CGFloat) {
            let pageMD = blockIndices.map { blocks[$0] }.joined(separator: "\n\n")
            let hosting = NSHostingView(rootView: makeMarkdownView(pageMD))
            hosting.frame = CGRect(x: 0, y: 0, width: viewWidth, height: 10)
            offscreenWindow.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let height = max(hosting.fittingSize.height, 1)
            return (hosting, height)
        }

        // === Iterative pack: try adding blocks until overflow, then back off ===
        //
        // We add blocks until the page can no longer fit even at the *minimum*
        // scale (`maxPageHeight`). Pages whose content exceeds `preferredPageHeight`
        // but is ≤ `maxPageHeight` will be rendered at a per-page scale that
        // shrinks them just enough to fit the paper — that's how we eliminate
        // the "image takes a portion of a page but is given the full page"
        // problem.
        var pages: [[Int]] = []
        var startIdx = 0
        while startIdx < blocks.count {
            var pageIndices: [Int] = []
            var nextIdx = startIdx
            while nextIdx < blocks.count {
                pageIndices.append(nextIdx)
                let (_, height) = renderPage(blockIndices: pageIndices)
                if height > maxPageHeight && pageIndices.count > 1 {
                    pageIndices.removeLast()
                    break
                }
                nextIdx += 1
            }
            pages.append(pageIndices)
            startIdx = (pageIndices.last ?? startIdx) + 1
        }

        // === Render each finalized page and write it into the PDF ===
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            print("Failed to create PDF context at: \(url.path)")
            return
        }

        for pageIndices in pages where !pageIndices.isEmpty {
            let (hosting, pageViewHeight) = renderPage(blockIndices: pageIndices)
            let pageBounds = NSSize(width: viewWidth, height: pageViewHeight)
            offscreenWindow.setContentSize(pageBounds)
            hosting.frame = CGRect(x: 0, y: 0, width: viewWidth, height: pageViewHeight)

            // SwiftUI preferences (table anchors, list bullet sizing, …) need
            // a couple of layout passes + a runloop tick to propagate before
            // we snapshot. Without this, table borders silently drop.
            hosting.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            hosting.layoutSubtreeIfNeeded()
            hosting.display()

            guard let bitmap = Self.snapshot(of: hosting, scale: 2.0) else { continue }

            ctx.beginPDFPage(nil)
            ctx.saveGState()

            // Per-page scale: pages whose content fits within `preferredPageHeight`
            // render at the preferred scale (consistent text size). Pages that
            // hold more content shrink uniformly so the whole thing lands inside
            // `pdfContentHeight` — this trades a slightly smaller font on that
            // page for eliminating the big whitespace gap at the bottom.
            let pageScale = min(preferredScale, pdfContentHeight / pageViewHeight)
            let pdfRenderedHeight = pageViewHeight * pageScale
            let pdfRenderedWidth = viewWidth * pageScale
            // Center the (possibly narrower) page content within the page's
            // content area so the left and right margins remain visually
            // balanced even when a page renders at a smaller scale.
            let imageRect = CGRect(
                x: margin + (pdfContentWidth - pdfRenderedWidth) / 2,
                y: pageSize.height - margin - pdfRenderedHeight,
                width: pdfRenderedWidth,
                height: pdfRenderedHeight
            )
            ctx.interpolationQuality = .high
            ctx.draw(bitmap, in: imageRect)

            ctx.restoreGState()
            ctx.endPDFPage()
        }

        ctx.closePDF()
        print("PDF saved successfully to: \(url.path)")
    }

    /// Rasterizes an NSView at the given scale by rendering its CALayer tree
    /// directly into a CGContext. This is more reliable than `cacheDisplay`,
    /// which sometimes returns a blank bitmap for NSHostingView under load
    /// (because SwiftUI's content lives in sublayers, not the view's
    /// `draw(_:)` method).
    private static func snapshot(of view: NSView, scale: CGFloat) -> CGImage? {
        let pixelW = Int(view.bounds.width * scale)
        let pixelH = Int(view.bounds.height * scale)
        guard pixelW > 0, pixelH > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        if let layer = view.layer {
            // CALayer renders in a Y-down coordinate space. The default CG
            // bitmap context is Y-up, so we flip the CTM before rendering so
            // the captured image isn't upside-down.
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: scale, y: -scale)
            layer.render(in: ctx)
        } else {
            ctx.scaleBy(x: scale, y: scale)
            // Fallback for any non-layer-backed view.
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: view.isFlipped)
            let prev = NSGraphicsContext.current
            NSGraphicsContext.current = nsCtx
            view.displayIgnoringOpacity(view.bounds, in: nsCtx)
            NSGraphicsContext.current = prev
        }

        return ctx.makeImage()
    }

    /// Splits a markdown source string into top-level block strings (CommonMark
    /// block elements). Each returned chunk renders to a single MarkdownUI
    /// block — paragraph, heading, table, fenced code, blockquote, or a
    /// (consecutive) list. This is what lets us paginate at the source level
    /// instead of trying to slice a tall rendered bitmap.
    static func splitMarkdownIntoBlocks(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var fence: Character? = nil

        func flush() {
            if !current.isEmpty {
                let block = current.joined(separator: "\n")
                if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(block)
                }
                current = []
            }
        }

        // Track whether the previous non-empty line was a list item so we can
        // keep a "loose list" (items separated by blank lines) as one block.
        var lastWasListItem = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a fenced code block, lines belong to the block until the
            // closing fence — blank lines included.
            if let f = fence {
                current.append(line)
                if trimmed.hasPrefix(String(repeating: f, count: 3)) {
                    fence = nil
                    flush()
                    lastWasListItem = false
                }
                continue
            }

            // Opening fence?
            if trimmed.hasPrefix("```") {
                flush()
                fence = "`"
                current.append(line)
                continue
            }
            if trimmed.hasPrefix("~~~") {
                flush()
                fence = "~"
                current.append(line)
                continue
            }

            if trimmed.isEmpty {
                // Blank lines normally separate blocks, except inside a loose
                // list — there we keep going so the list stays as one chunk.
                if lastWasListItem {
                    current.append(line)
                } else {
                    flush()
                }
                continue
            }

            let isListItem = Self.lineLooksLikeListItem(trimmed)
            if !isListItem && lastWasListItem {
                // The blank line we just appended was actually a list-ending
                // separator; close the previous list block before continuing.
                if let lastNonEmpty = current.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    let listLines = Array(current[0...lastNonEmpty])
                    let trailingBlanks = Array(current[(lastNonEmpty + 1)...])
                    current = listLines
                    flush()
                    current = trailingBlanks
                }
            }

            current.append(line)
            lastWasListItem = isListItem
        }
        flush()
        return blocks
    }

    private static func lineLooksLikeListItem(_ trimmed: String) -> Bool {
        // Unordered list bullets: -, *, +
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        // Ordered list: digit(s) followed by `.` or `)`
        var idx = trimmed.startIndex
        var sawDigit = false
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            sawDigit = true
            idx = trimmed.index(after: idx)
        }
        if sawDigit, idx < trimmed.endIndex {
            let c = trimmed[idx]
            if (c == "." || c == ")"),
               let nextIdx = trimmed.index(idx, offsetBy: 1, limitedBy: trimmed.endIndex),
               nextIdx < trimmed.endIndex,
               trimmed[nextIdx] == " " {
                return true
            }
        }
        return false
    }


    /// Scans the markdown for `![alt](url)` image references with absolute
    /// http/https URLs and downloads each in parallel.
    static func preloadRemoteImages(in markdown: String) async -> [URL: NSImage] {
        let urls = extractImageURLs(from: markdown)
        guard !urls.isEmpty else { return [:] }

        return await withTaskGroup(of: (URL, NSImage?).self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        return (url, NSImage(data: data))
                    } catch {
                        return (url, nil)
                    }
                }
            }
            var cache: [URL: NSImage] = [:]
            for await (url, image) in group {
                if let image = image {
                    cache[url] = image
                }
            }
            return cache
        }
    }

    private static func extractImageURLs(from markdown: String) -> [URL] {
        // Matches `![alt](https://…)` — captures the URL portion.
        let pattern = #"!\[[^\]]*\]\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var seen: Set<URL> = []
        var result: [URL] = []
        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            guard
                let match = match,
                match.numberOfRanges >= 2,
                let urlRange = Range(match.range(at: 1), in: markdown),
                let url = URL(string: String(markdown[urlRange])),
                !seen.contains(url)
            else { return }
            seen.insert(url)
            result.append(url)
        }
        return result
    }
}

/// MarkdownUI image provider that returns pre-downloaded images synchronously.
/// Falls back to a transparent placeholder when a URL isn't in the cache, so
/// the PDF render path never has to await an async image load.
struct PreloadedImageProvider: ImageProvider {
    let cache: [URL: NSImage]

    func makeImage(url: URL?) -> some View {
        if let url, let image = cache[url] {
            return AnyView(
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
        }
        return AnyView(Color.clear.frame(width: 0, height: 0))
    }
}
