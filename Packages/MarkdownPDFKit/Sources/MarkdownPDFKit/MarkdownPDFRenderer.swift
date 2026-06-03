//
//  MarkdownPDFRenderer.swift
//  MarkdownPDFKit
//
//  The rendering engine that turns a Markdown string into a paginated,
//  pixel-accurate PDF. Shared by the md2pdf app (macOS + iOS) and the
//  md2pdf-cli tool.
//
//  Pipeline:
//    1. source-level preprocessing (footnotes, LaTeX→Unicode math)
//    2. mermaid diagrams rendered via WKWebView → embedded images
//    3. remote images preloaded so they render synchronously
//    4. block-level pagination: split source into blocks, greedily pack
//       blocks onto pages, never slicing a block across a page boundary
//    5. each page rendered as its own MarkdownUI view via SwiftUI's
//       `ImageRenderer`, then drawn into a CGPDFContext at a per-page scale
//
//  `ImageRenderer` (macOS 13 / iOS 16) rasterizes a SwiftUI view off-screen
//  with no window or hosting view, which is what keeps this engine portable
//  across AppKit and UIKit — there is no platform-specific offscreen-window
//  machinery here anymore.
//

import SwiftUI
import PDFKit
import Markdown
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
public enum MarkdownPDFRenderer {

    /// Page geometry + scaling knobs. A4 at 72dpi with 50pt margins.
    public struct Layout {
        public var pageWidth: CGFloat = 595
        public var pageHeight: CGFloat = 842
        public var margin: CGFloat = 50
        /// Preferred (and maximum) render scale. Sets the default body text
        /// size on paper — 0.82 puts the docC 13pt body around 10.7pt.
        public var preferredScale: CGFloat = 0.82
        /// Smallest per-page scale. Pages that *almost* fit one more block
        /// at the preferred scale shrink down to (at most) this, so the
        /// extra block can be included instead of leaving a half-empty page.
        public var minScale: CGFloat = 0.70
        public init() {}
    }

    /// Render `markdown` into a PDF written to `url`.
    public static func render(markdown: String, to url: URL, layout: Layout = Layout()) async {
        let pageSize = CGSize(width: layout.pageWidth, height: layout.pageHeight)
        let margin = layout.margin
        let pdfContentWidth = pageSize.width - 2 * margin
        let pdfContentHeight = pageSize.height - 2 * margin
        let preferredScale = layout.preferredScale
        let minScale = layout.minScale
        let viewWidth = pdfContentWidth / preferredScale
        let maxPageHeight = pdfContentHeight / minScale

        // 1. Source-level transforms.
        var processedMarkdown = MarkdownPreprocessor.process(markdown)

        // 2. Mermaid diagrams → images, keyed by their (trimmed) source. The
        //    ```mermaid blocks are LEFT IN PLACE: the `md2pdf` theme's
        //    code-block style renders them as scaled-to-fit images via this
        //    map, instead of routing them through MarkdownUI's block-image
        //    layout (which ignores width constraints and clips wide diagrams).
        let mermaidCodes = MarkdownPreprocessor.extractMermaid(processedMarkdown)
        let renderedMermaid = await MermaidRenderer.renderAll(mermaidCodes)
        var mermaidImages: [String: PlatformImage] = [:]
        for (code, image) in renderedMermaid {
            mermaidImages[code.trimmingCharacters(in: .whitespacesAndNewlines)] =
                image.scaledDown(toWidth: viewWidth)
        }

        // 3. Remote images preloaded.
        let imageCache = await preloadRemoteImages(in: processedMarkdown)

        // 4. Block-level pagination.
        let blocks = splitMarkdownIntoBlocks(processedMarkdown)
        guard !blocks.isEmpty else {
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            if let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) {
                ctx.beginPDFPage(nil)
                ctx.endPDFPage()
                ctx.closePDF()
            }
            return
        }

        let makeMarkdownView: (String) -> AnyView = { md in
            AnyView(
                Markdown(md)
                    .markdownTheme(.md2pdf)
                    .mermaidImages(mermaidImages)
                    .markdownImageProvider(PreloadedImageProvider(cache: imageCache, containerWidth: viewWidth))
                    .markdownCodeSyntaxHighlighter(SyntaxHighlighter())
                    .frame(width: viewWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
            )
        }

        let host = OffscreenViewHost(width: viewWidth)
        defer { host.teardown() }

        func pageMarkdown(_ blockIndices: [Int]) -> String {
            blockIndices.map { blocks[$0] }.joined(separator: "\n\n")
        }

        // Greedy pack: add blocks until the page can't fit even at minScale.
        var pages: [[Int]] = []
        var startIdx = 0
        while startIdx < blocks.count {
            var pageIndices: [Int] = []
            var nextIdx = startIdx
            while nextIdx < blocks.count {
                pageIndices.append(nextIdx)
                let height = host.measureHeight(makeMarkdownView(pageMarkdown(pageIndices)))
                if height > maxPageHeight && pageIndices.count > 1 {
                    pageIndices.removeLast()
                    break
                }
                nextIdx += 1
            }
            pages.append(pageIndices)
            startIdx = (pageIndices.last ?? startIdx) + 1
        }

        // 5. Render each page into the PDF.
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            return
        }

        for pageIndices in pages where !pageIndices.isEmpty {
            let pageMD = pageMarkdown(pageIndices)
            let pageView = makeMarkdownView(pageMD)
            let pageViewHeight = host.measureHeight(pageView)

            guard let bitmap = host.snapshot(pageView, height: pageViewHeight, scale: 2.0) else { continue }

            ctx.beginPDFPage(nil)
            ctx.saveGState()

            let pageScale = min(preferredScale, pdfContentHeight / pageViewHeight)
            let pdfRenderedHeight = pageViewHeight * pageScale
            let pdfRenderedWidth = viewWidth * pageScale
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
    }

    // MARK: - Live preview image

    /// Render the markdown to a single bitmap at `width`, the same way the PDF
    /// is rendered (off-screen SwiftUI snapshot) — so the live preview matches
    /// the export exactly and wide content like mermaid diagrams shrink to fit
    /// instead of overflowing. MarkdownUI's *live* layout doesn't constrain
    /// block-image width, but the off-screen render does, so we render once and
    /// show the image.
    public static func renderToImage(markdown: String, width: CGFloat, scale: CGFloat = 2) async -> PlatformImage? {
        guard width > 1 else { return nil }

        var processed = MarkdownPreprocessor.process(markdown)

        // Mermaid blocks stay in place; the theme renders them as scaled-to-fit
        // images via this map (see `render(markdown:to:)` step 2 for why).
        let mermaidCodes = MarkdownPreprocessor.extractMermaid(processed)
        let renderedMermaid = await MermaidRenderer.renderAll(mermaidCodes)
        var mermaidImages: [String: PlatformImage] = [:]
        for (code, image) in renderedMermaid {
            mermaidImages[code.trimmingCharacters(in: .whitespacesAndNewlines)] =
                image.scaledDown(toWidth: width)
        }
        let imageCache = await preloadRemoteImages(in: processed)

        guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let view = AnyView(
            Markdown(processed)
                .markdownTheme(.md2pdf)
                .mermaidImages(mermaidImages)
                .markdownImageProvider(PreloadedImageProvider(cache: imageCache, containerWidth: width))
                .markdownCodeSyntaxHighlighter(SyntaxHighlighter())
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )

        let host = OffscreenViewHost(width: width)
        defer { host.teardown() }
        let height = host.measureHeight(view)
        guard let cg = host.snapshot(view, height: height, scale: scale) else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        #endif
    }

    // MARK: - Block splitting

    /// Splits a markdown source string into top-level block strings.
    public static func splitMarkdownIntoBlocks(_ markdown: String) -> [String] {
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

        var lastWasListItem = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let f = fence {
                current.append(line)
                if trimmed.hasPrefix(String(repeating: f, count: 3)) {
                    fence = nil
                    flush()
                    lastWasListItem = false
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flush(); fence = "`"; current.append(line); continue
            }
            if trimmed.hasPrefix("~~~") {
                flush(); fence = "~"; current.append(line); continue
            }

            if trimmed.isEmpty {
                if lastWasListItem { current.append(line) } else { flush() }
                continue
            }

            let isListItem = lineLooksLikeListItem(trimmed)
            if !isListItem && lastWasListItem {
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
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
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

    // MARK: - Remote image preloading

    /// Scans the markdown for `![alt](https://…)` image references and
    /// downloads each in parallel so they can be rendered synchronously.
    public static func preloadRemoteImages(in markdown: String) async -> [URL: PlatformImage] {
        let urls = extractImageURLs(from: markdown)
        guard !urls.isEmpty else { return [:] }

        return await withTaskGroup(of: (URL, PlatformImage?).self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        return (url, PlatformImage(data: data))
                    } catch {
                        return (url, nil)
                    }
                }
            }
            var cache: [URL: PlatformImage] = [:]
            for await (url, image) in group {
                if let image { cache[url] = image }
            }
            return cache
        }
    }

    private static func extractImageURLs(from markdown: String) -> [URL] {
        let pattern = #"!\[[^\]]*\]\((https?://[^\s)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var seen: Set<URL> = []
        var result: [URL] = []
        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            guard
                let match,
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

/// MarkdownUI image provider that returns pre-downloaded images sized to fit
/// the column. Used by both the live preview and the PDF renderer.
///
/// `containerWidth` is the width of the column the markdown is laid out in.
/// We must use an explicit *fixed* frame (not `scaledToFit`/`maxWidth`):
/// MarkdownUI lays block images out in its own `FlowLayout`, which proposes
/// the image's natural width — so a flexible image takes its full size and
/// overflows/clips. A fixed frame is respected, so wide diagrams (mermaid)
/// shrink to fit. Falls back to natural width when no container width is set.
public struct PreloadedImageProvider: ImageProvider {
    let cache: [URL: PlatformImage]
    let containerWidth: CGFloat?

    public init(cache: [URL: PlatformImage], containerWidth: CGFloat? = nil) {
        self.cache = cache
        self.containerWidth = containerWidth
    }

    public func makeImage(url: URL?) -> some View {
        if let url, let image = cache[url] {
            // Physically shrink the bitmap to the column width if it's wider,
            // then show it as a NON-resizable image. MarkdownUI's FlowLayout
            // ignores frame constraints and would upscale a resizable image
            // back to its proposed (natural) width; a fixed-size image is
            // locked to the (already-fitted) bitmap size and can't overflow.
            // Divide by the snapshot's raster scale so it lands at the column
            // width after the off-screen render scales it (see
            // `OffscreenViewHost.rasterImageScale`).
            let target = containerWidth.map { $0 / OffscreenViewHost.rasterImageScale }
            let display = target.map { image.scaledDown(toWidth: $0) } ?? image
            return AnyView(Image(platformImage: display))
        }
        return AnyView(Color.clear.frame(width: 0, height: 0))
    }
}
