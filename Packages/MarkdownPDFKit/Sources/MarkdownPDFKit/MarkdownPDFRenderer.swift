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

        // 2. Mermaid diagrams → images.
        let mermaidCodes = MarkdownPreprocessor.extractMermaid(processedMarkdown)
        let mermaidImages = await MermaidRenderer.renderAll(mermaidCodes)
        var mermaidURLMap: [String: URL] = [:]
        var mermaidImageCache: [URL: PlatformImage] = [:]
        for (code, image) in mermaidImages {
            let u = URL(string: "mermaidimg://\(UUID().uuidString)")!
            mermaidURLMap[code] = u
            mermaidImageCache[u] = image
        }
        processedMarkdown = MarkdownPreprocessor.replaceMermaid(
            in: processedMarkdown, withImageURLs: mermaidURLMap
        )

        // 3. Remote images preloaded.
        var imageCache = await preloadRemoteImages(in: processedMarkdown)
        imageCache.merge(mermaidImageCache) { current, _ in current }

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
                    .markdownTheme(.docC)
                    .markdownImageProvider(PreloadedImageProvider(cache: imageCache))
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

/// MarkdownUI image provider that returns pre-downloaded images at their
/// natural size — capped to the column width so large downloads don't blow
/// out the layout. Used by both the live preview and the PDF renderer.
public struct PreloadedImageProvider: ImageProvider {
    let cache: [URL: PlatformImage]

    public init(cache: [URL: PlatformImage]) {
        self.cache = cache
    }

    public func makeImage(url: URL?) -> some View {
        if let url, let image = cache[url] {
            return AnyView(
                ScaleDownToFit(idealSize: image.size) {
                    Image(platformImage: image).resizable()
                }
            )
        }
        return AnyView(Color.clear.frame(width: 0, height: 0))
    }
}

/// Lays an image out at its natural size, but scales it DOWN to fit the
/// available width (preserving aspect ratio) when the column is narrower —
/// so wide diagrams (e.g. mermaid flowcharts) shrink to fit on a narrow
/// iPhone column instead of overflowing and getting clipped. Never upscales.
struct ScaleDownToFit: Layout {
    let idealSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard idealSize.width > 0, idealSize.height > 0 else { return .zero }
        var size = idealSize
        if let width = proposal.width, width < idealSize.width {
            size.width = width
            size.height = width * (idealSize.height / idealSize.width)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}
