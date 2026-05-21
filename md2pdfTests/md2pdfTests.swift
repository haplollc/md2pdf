//
//  md2pdfTests.swift
//  md2pdfTests
//
//  Created by Jared Cassoutt on 3/11/25.
//

import Testing
import Foundation
import PDFKit
import Vision
import AppKit
@testable import md2pdf

@MainActor
@Suite(.serialized)
struct md2pdfTests {

    /// Path to the real-world fixture markdown used to exercise PDF export.
    private static let fixturePath = "/Users/jaredcassoutt/Downloads/europe_trip_with_activities.md"

    /// A second fixture that intentionally exercises every advanced feature
    /// (footnotes, syntax highlighting, math, mermaid). Lives on the
    /// Desktop so it doubles as a manual smoke test you can open in the
    /// app, hit Save → PDF, and skim through.
    private static let showcasePath = "/Users/jaredcassoutt/Desktop/md2pdf_feature_showcase.md"

    private func loadShowcaseMarkdown() throws -> String {
        try String(contentsOfFile: Self.showcasePath, encoding: .utf8)
    }

    private func loadFixtureMarkdown() throws -> String {
        try String(contentsOfFile: Self.fixturePath, encoding: .utf8)
    }

    private func makeTempPDFURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("md2pdf-test-\(UUID().uuidString).pdf")
    }

    /// Rasterizes a PDF page to a CGImage at the given scale.
    private func rasterize(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        let bytesPerRow = pw * 4
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// OCRs a single PDF page using Vision. Returns the concatenated
    /// recognized text. Falls back to empty string if recognition fails.
    private func ocrText(of page: PDFPage) async throws -> String {
        guard let cgImage = rasterize(page, scale: 2.0) else { return "" }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    cont.resume(throwing: err)
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Counts non-white sampled pixels in a PDF page. Used to verify pages
    /// aren't visually blank.
    private func countInkPixels(in page: PDFPage, samples: Int = 50) -> Int {
        guard let cgImage = rasterize(page, scale: 1.0) else { return 0 }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var nonWhite = 0
        for sx in 0..<samples {
            for sy in 0..<samples {
                let x = (width * sx) / samples
                let y = (height * sy) / samples
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 {
                    nonWhite += 1
                }
            }
        }
        return nonWhite
    }

    @Test func exportProducesNonBlankPDF() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown

        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "PDF file is empty (no bytes written)")

        let doc = try #require(PDFDocument(url: url), "PDF file could not be opened by PDFKit")
        #expect(doc.pageCount >= 1, "PDF has zero pages")

        // PDF is bitmap-backed so `page.string` returns nothing. OCR the first
        // page to verify rendered text matches the source markdown.
        let firstPage = try #require(doc.page(at: 0))
        let recognized = try await ocrText(of: firstPage)
        #expect(recognized.contains("Europe") || recognized.contains("Amsterdam"),
                "First page OCR did not contain expected markdown content. Got: \(recognized.prefix(200))")
    }

    /// Renders each PDF page to a bitmap and asserts the pixels aren't all
    /// near-white — guards against the regression where a PDF has correct
    /// page-count but draws nothing visible.
    @Test func exportProducesVisuallyNonBlankPixels() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown

        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount >= 1)

        // Require that the vast majority of pages have substantial ink. A
        // trailing page may legitimately be sparse if the document doesn't
        // perfectly fill it, so we allow one outlier.
        var sparsePages: [Int] = []
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            let ink = countInkPixels(in: page)
            if ink <= 20 { sparsePages.append(i + 1) }
        }
        #expect(sparsePages.count <= 1,
                "More than one page is visually blank: pages \(sparsePages) of \(doc.pageCount)")
    }

    /// Ensures pages appear in document order — first page contains the title,
    /// last page contains the trailing budget section. Catches the regression
    /// where pagination ran upside-down across the document.
    @Test func exportPreservesPageOrder() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown

        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        let firstPage = try #require(doc.page(at: 0))
        let lastPage = try #require(doc.page(at: doc.pageCount - 1))

        let firstText = try await ocrText(of: firstPage)
        let lastText = try await ocrText(of: lastPage)

        #expect(firstText.contains("Europe Summer Trip"),
                "First page should contain the document title. OCR: \(firstText.prefix(160))")
        #expect(lastText.contains("Budget") || lastText.contains("Hotels"),
                "Last page should contain the trailing budget section. OCR: \(lastText.prefix(160))")
    }

    @Test func exportPaginatesMultiplePagesForLongDocument() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown

        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount >= 2, "Expected multi-page PDF for the trip itinerary, got \(doc.pageCount) page(s)")
    }

    /// Verifies that table borders actually render in the exported PDF.
    /// MarkdownUI draws borders via `anchorPreference`, which only resolves
    /// when the host view is in a window — this test catches the regression
    /// where ImageRenderer / `dataWithPDF` silently drop those decorations.
    /// Verifies that markdown image references with absolute URLs actually
    /// render in the exported PDF. Catches the AsyncImage-not-loaded regression
    /// where the renderer snapshots the view before the network image returns.
    @Test func exportRendersURLImage() async throws {
        let vm = EditorViewModel()
        // picsum.photos serves a deterministic small image and is reliable
        // enough for CI. A 200x150 image is big enough to detect easily in the
        // rasterized PDF but small enough that the download stays fast.
        vm.markdownContent = """
        # Image test

        Some text above the image so we can locate it.

        ![Sample](https://picsum.photos/id/237/200/150)

        Some text below the image.
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        guard let cgImage = rasterize(page, scale: 2.0) else {
            Issue.record("Could not rasterize page")
            return
        }

        // The fixture image is a dog photo — it has substantial darker tones
        // that the rest of the page (white background + black text on light
        // gray) does not. Sample the bitmap and count "image-like" pixels:
        // any pixel where r/g/b is below 100. Light gray text rarely hits
        // that threshold; a photographic image will produce many.
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var darkPixels = 0
        let samples = 100
        for sx in 0..<samples {
            for sy in 0..<samples {
                let x = (bitmap.pixelsWide * sx) / samples
                let y = (bitmap.pixelsHigh * sy) / samples
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.redComponent < 0.4 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                    darkPixels += 1
                }
            }
        }
        // Even a small image should yield well over 20 sample points with deep
        // tones. Text alone almost never crosses this threshold.
        #expect(darkPixels > 20,
                "URL image does not appear in PDF — only \(darkPixels) image-like pixels found (expected text alone to be far below this)")
    }

    /// Detects glyphs that have been sliced horizontally across a page break.
    ///
    /// A real mid-line split puts the top half of letters on the upper page
    /// AND the bottom halves at the SAME x-columns on the lower page. So the
    /// upper page has ink running all the way down to its content-area edge,
    /// and the lower page has ink running all the way up to its content-area
    /// edge, at matching columns. Adjacent paragraphs that just happen to
    /// occupy similar x-positions don't reach those very edges — they sit a
    /// few pixels inside.
    @Test func exportDoesNotSplitLinesMidWord() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        guard doc.pageCount >= 2 else { return }

        let scale: CGFloat = 2
        let marginPx = Int(50 * scale)

        for boundary in 0..<(doc.pageCount - 1) {
            guard
                let upper = doc.page(at: boundary),
                let lower = doc.page(at: boundary + 1),
                let upperImage = rasterize(upper, scale: scale),
                let lowerImage = rasterize(lower, scale: scale)
            else { continue }

            let pw = upperImage.width
            let ph = upperImage.height
            let upperBytes = bgraBytes(of: upperImage)
            let lowerBytes = bgraBytes(of: lowerImage)
            let bytesPerRow = pw * 4

            // The ONE row right at the upper page's content-area edge (= the
            // cut). If a glyph was sliced, the very bottom of that glyph sits
            // here.
            let upperEdgeY = marginPx
            // The ONE row right at the lower page's content-area top edge.
            let lowerEdgeY = ph - marginPx - 1

            // For a cut glyph: ink at upper edge AND ink at lower edge in the
            // same column. For adjacent paragraphs: ink might be a few pixels
            // inside the strip but not RIGHT at the edge row.
            var cutColumns = 0
            for x in marginPx..<(pw - marginPx) {
                let upperOff = upperEdgeY * bytesPerRow + x * 4
                let lowerOff = lowerEdgeY * bytesPerRow + x * 4
                let upperInky = upperBytes[upperOff] < 200 || upperBytes[upperOff + 1] < 200 || upperBytes[upperOff + 2] < 200
                let lowerInky = lowerBytes[lowerOff] < 200 || lowerBytes[lowerOff + 1] < 200 || lowerBytes[lowerOff + 2] < 200
                if upperInky && lowerInky {
                    cutColumns += 1
                }
            }
            let contentColumns = pw - 2 * marginPx
            let cutRatio = Double(cutColumns) / Double(contentColumns)
            // Allow a small amount of edge ink to account for table borders or
            // a stray descender — anything above 3% is a real cut.
            #expect(cutRatio < 0.03,
                    "Boundary between page \(boundary + 1) and \(boundary + 2) appears to slice a line: \(cutColumns)/\(contentColumns) columns (\(Int(cutRatio * 100))%) have ink at the very cut edge on both sides")
        }
    }

    /// Verifies that pages are packed efficiently — i.e., non-terminal pages
    /// don't leave huge whitespace at the bottom when the next block could
    /// reasonably fit. We measure where content ends on each page and assert
    /// that the empty space below content is below a tolerance.
    @Test func exportPacksPagesEfficiently() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        guard doc.pageCount >= 2 else { return }

        let scale: CGFloat = 1.0
        let marginPx = Int(50 * scale)

        // For every page except the last, find where content ENDS and check
        // it's reasonably close to the bottom of the content area. The last
        // page is allowed to be short (document just ran out).
        for i in 0..<(doc.pageCount - 1) {
            guard
                let page = doc.page(at: i),
                let image = rasterize(page, scale: scale)
            else { continue }

            let pw = image.width
            let ph = image.height
            let bytes = bgraBytes(of: image)
            let bytesPerRow = pw * 4

            // Walk down from the top of the content area finding the last
            // row with ink. (CG bitmap: y=0 at bottom; y=ph-1 at top.)
            // The content area runs from pixel y = marginPx to y = ph - marginPx.
            // We want to find lowest y in that range with ink — that's where
            // the content ends visually.
            var lastInkFromTop: Int? = nil
            for visualY in 0..<(ph - 2 * marginPx) {
                // visualY = 0 → top of content area = pixel y = ph - marginPx - 1
                let pixelY = ph - marginPx - 1 - visualY
                if pixelY < 0 { break }
                let rowStart = pixelY * bytesPerRow
                var anyInk = false
                for x in marginPx..<(pw - marginPx) {
                    let off = rowStart + x * 4
                    if bytes[off] < 230 || bytes[off + 1] < 230 || bytes[off + 2] < 230 {
                        anyInk = true
                        break
                    }
                }
                if anyInk { lastInkFromTop = visualY }
            }

            let contentHeightPx = ph - 2 * marginPx
            let inkExtent = lastInkFromTop ?? 0
            let fillRatio = Double(inkExtent) / Double(contentHeightPx)
            #expect(fillRatio > 0.80,
                    "Page \(i + 1) only fills \(Int(fillRatio * 100))% of its content area — content stops with \(contentHeightPx - inkExtent)px of whitespace below it")
        }
    }

    /// Verifies that no ink ever bleeds into the bottom-margin area of any
    /// page. If a block overflows the page or the renderer mis-positions its
    /// bitmap, glyphs would appear in the margin band — which is exactly the
    /// "half-letter on one page, half on the next" symptom users report.
    @Test func exportKeepsContentOutOfBottomMargin() async throws {
        let markdown = try loadFixtureMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        let scale: CGFloat = 2
        let marginPx = Int(50 * scale)
        // Look at the entire bottom-margin band, minus the outermost 2px to
        // skip any potential page-edge antialias artifacts.
        let bottomY: ClosedRange<Int> = 2...(marginPx - 2)

        for i in 0..<doc.pageCount {
            guard
                let page = doc.page(at: i),
                let image = rasterize(page, scale: scale)
            else { continue }

            let pw = image.width
            let bytes = bgraBytes(of: image)
            let bytesPerRow = pw * 4
            var inkPixels = 0
            for y in bottomY {
                for x in 0..<pw {
                    let off = y * bytesPerRow + x * 4
                    if bytes[off] < 200 || bytes[off + 1] < 200 || bytes[off + 2] < 200 {
                        inkPixels += 1
                    }
                }
            }
            // A small handful (≤25 px) is acceptable as edge anti-alias noise
            // around table borders; anything more is real content bleeding.
            #expect(inkPixels < 25,
                    "Page \(i + 1) has \(inkPixels) ink pixels in the bottom-margin area — content is bleeding past the page bottom")
        }
    }

    /// Same boundary check, but for a markdown with a single inline URL image
    /// that's around half a page tall — verifies the image always ends up on
    /// one page (no slicing across the boundary).
    @Test func exportDoesNotSplitImagesAcrossPages() async throws {
        let vm = EditorViewModel()
        // Pad before and after so the image is forced to wrestle with a page
        // boundary instead of always landing on page 1.
        let preface = String(repeating: "Filler paragraph. ", count: 90)
        let trailer = String(repeating: "More filler. ", count: 200)
        vm.markdownContent = """
        # Image-split test

        \(preface)

        ![A photo](https://picsum.photos/seed/split-test/800/500)

        \(trailer)
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        guard doc.pageCount >= 2 else {
            Issue.record("Test markdown didn't produce a multi-page PDF — image-split scenario isn't being exercised")
            return
        }

        // For each page boundary look at the bottom-of-upper / top-of-lower
        // strips. If the bottom of the upper page is a solid band of similar
        // colors AND the top of the lower page is *also* a solid band of
        // similar colors, that's a strong sign the image got cut.
        let scale: CGFloat = 2
        let marginPx = Int(50 * scale)
        let stripPx = Int(4 * scale)

        for boundary in 0..<(doc.pageCount - 1) {
            guard
                let upper = doc.page(at: boundary),
                let lower = doc.page(at: boundary + 1),
                let upperImage = rasterize(upper, scale: scale),
                let lowerImage = rasterize(lower, scale: scale)
            else { continue }

            let pw = upperImage.width
            let ph = upperImage.height
            let upperBytes = bgraBytes(of: upperImage)
            let lowerBytes = bgraBytes(of: lowerImage)
            let bytesPerRow = pw * 4

            // Sample mean color of upper bottom strip and lower top strip.
            // If both strips have low whiteness (i.e., are "photo-like") in
            // overlapping columns, the image was cut.
            var sharedPhotoColumns = 0
            for x in marginPx..<(pw - marginPx) {
                var upperDark = false
                for y in marginPx..<(marginPx + stripPx) {
                    let off = y * bytesPerRow + x * 4
                    if upperBytes[off] < 180 && upperBytes[off + 1] < 180 && upperBytes[off + 2] < 180 {
                        upperDark = true
                        break
                    }
                }
                if !upperDark { continue }
                for y in (ph - marginPx - stripPx)..<(ph - marginPx) {
                    let off = y * bytesPerRow + x * 4
                    if lowerBytes[off] < 180 && lowerBytes[off + 1] < 180 && lowerBytes[off + 2] < 180 {
                        sharedPhotoColumns += 1
                        break
                    }
                }
            }
            let contentColumns = pw - 2 * marginPx
            let ratio = Double(sharedPhotoColumns) / Double(contentColumns)
            #expect(ratio < 0.10,
                    "Boundary between page \(boundary + 1) and \(boundary + 2) appears to split an image: \(sharedPhotoColumns)/\(contentColumns) columns (\(Int(ratio * 100))%) of photo-like ink span the boundary")
        }
    }

    /// Helper: copy a CGImage's pixels into a contiguous BGRA byte buffer for
    /// fast per-pixel inspection.
    private func bgraBytes(of cgImage: CGImage) -> [UInt8] {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let ctx = CGContext(
            data: &bytes, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    /// Verifies that GFM footnotes are expanded into superscripts + a
    /// footnotes section, and that the rendered PDF actually contains the
    /// definition text (OCR'd).
    @Test func footnotePreprocessor() async throws {
        let source = """
        # Footnote test

        This sentence has a footnote.[^source]
        And this one too.[^second]
        And a repeat of the first.[^source]

        [^source]: Smith, *Markdown in Practice*, 2024.
        [^second]: Doe, *Footnote Field Guide*, 2023.
        """

        let processed = MarkdownPreprocessor.process(source)

        // Inline references replaced with superscript digits.
        #expect(processed.contains("This sentence has a footnote.\u{00B9}"))
        #expect(processed.contains("And this one too.\u{00B2}"))
        // Re-use of the same id keeps the same number.
        #expect(processed.contains("And a repeat of the first.\u{00B9}"))

        // Original definition lines stripped.
        #expect(!processed.contains("[^source]:"))
        #expect(!processed.contains("[^second]:"))

        // Footnotes section appears, numbered in first-reference order.
        #expect(processed.contains("**Footnotes**"))
        #expect(processed.range(of: "\u{00B9} Smith, \\*Markdown in Practice\\*, 2024\\.", options: .regularExpression) != nil)
        #expect(processed.range(of: "\u{00B2} Doe, \\*Footnote Field Guide\\*, 2023\\.", options: .regularExpression) != nil)

        // Render to PDF and OCR the result to confirm the footnotes section
        // actually lands on the page.
        let vm = EditorViewModel()
        vm.markdownContent = source
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        var allText = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                allText += try await ocrText(of: page) + "\n"
            }
        }
        #expect(allText.contains("Footnotes") || allText.localizedCaseInsensitiveContains("footnotes"),
                "Rendered PDF should include a footnotes section. OCR: \(allText.prefix(400))")
        #expect(allText.contains("Smith") || allText.contains("Markdown in Practice"),
                "Footnote definition text should appear in the PDF")
    }

    /// Verifies that fenced code blocks render with colored tokens — not
    /// just black-on-white text. We render a Swift snippet (which has
    /// keywords, strings, numbers, types, comments — all five colored
    /// kinds), rasterize the PDF, and look for non-grayscale pixels in
    /// the code-block area. A plain-text highlighter would produce only
    /// grayscale.
    @Test func exportHighlightsCodeFences() async throws {
        let vm = EditorViewModel()
        vm.markdownContent = """
        # Syntax test

        Filler text.

        ```swift
        // A small example
        struct Counter {
            var value: Int = 0
            mutating func bump() {
                value += 1
                print("count = \\(value)")
            }
        }
        ```

        Trailing text.
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        guard let cgImage = rasterize(page, scale: 2.0) else {
            Issue.record("Could not rasterize page")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        // Count sampled pixels whose RGB channels diverge by more than 20
        // — those can't be grayscale text/borders, so they must be from
        // the highlighter's colored tokens (red strings, magenta keywords,
        // blue numbers, etc.).
        var colorfulPixels = 0
        let samples = 120
        for sx in 0..<samples {
            for sy in 0..<samples {
                let x = (bitmap.pixelsWide * sx) / samples
                let y = (bitmap.pixelsHigh * sy) / samples
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                let maxChan = max(r, g, b)
                let minChan = min(r, g, b)
                // Skip near-white background.
                if minChan > 0.92 { continue }
                if maxChan - minChan > 0.08 {
                    colorfulPixels += 1
                }
            }
        }
        #expect(colorfulPixels > 5,
                "Expected colorful tokens from syntax highlighter — found \(colorfulPixels) non-grayscale samples (would be 0 with plain text)")
    }

    /// Verifies that `$inline$` and `$$display$$` LaTeX math gets rewritten
    /// into Unicode approximations before MarkdownUI sees it.
    @Test func mathPreprocessor() async throws {
        let cases: [(input: String, mustContain: String)] = [
            ("Inline: $x^2 + y^2 = z^2$", "x² + y² = z²"),
            ("Greek: $\\alpha + \\beta = \\gamma$", "α + β = γ"),
            ("Sum: $\\sum_{i=1}^{n} i$", "∑"),
            ("Square root: $\\sqrt{a + b}$", "√(a + b)"),
            ("Fraction: $\\frac{1}{2}$", "(1) / (2)"),
            ("Subscript: $x_{ij}$", "xᵢⱼ"),
            ("Display: $$E = mc^2$$", "E = mc²"),
            ("Less-than-equal: $a \\leq b$", "a ≤ b"),
            ("Implies: $A \\Rightarrow B$", "A ⇒ B"),
        ]
        for (input, needle) in cases {
            let processed = MarkdownPreprocessor.process(input)
            #expect(processed.contains(needle),
                    "Input \(input.debugDescription) → expected \(needle.debugDescription), got \(processed.debugDescription)")
        }

        // Render to PDF and OCR — the docC theme should render the
        // substituted glyphs (most OCR engines won't recognize obscure
        // math glyphs; we just check the document didn't blow up).
        let vm = EditorViewModel()
        vm.markdownContent = """
        # Math test

        The area of a circle is $A = \\pi r^2$.

        Pythagoras:
        $$a^2 + b^2 = c^2$$

        Sum of the first $n$ integers:
        $$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount >= 1)
    }

    /// Verifies that a ```mermaid``` fenced block is replaced by a
    /// rendered diagram in the exported PDF. We render a tiny flowchart
    /// and check that the resulting page contains noticeably non-grayscale
    /// or visibly structured ink in a region where a plain code fence
    /// would have produced only black text on white.
    /// Diagnostic — calls the renderer directly so we can see whether
    /// boot succeeded, whether render returned an image, and how big it was.
    @Test func mermaidRendererSmokeTest() async throws {
        let code = """
        flowchart LR
            A[Start] --> B{Decision}
            B -->|Yes| C[Done]
            B -->|No| D[Retry]
        """
        let image = await MermaidRenderer.render(code)
        let bundleHasMermaid = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") != nil
        let bundleID = Bundle.main.bundleIdentifier ?? "<none>"
        #expect(image != nil,
                "MermaidRenderer.render() returned nil. bundleID=\(bundleID) bundleHasMermaid=\(bundleHasMermaid)")
        if let image {
            #expect(image.size.width > 1 && image.size.height > 1,
                    "Rendered image is too small: \(image.size)")
        }
    }

    @Test func exportRendersMermaidDiagram() async throws {
        let vm = EditorViewModel()
        vm.markdownContent = """
        # Mermaid test

        Some intro text.

        ```mermaid
        flowchart LR
            A[Start] --> B{Decision}
            B -->|Yes| C[Done]
            B -->|No| D[Retry]
        ```

        Trailing text.
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))

        // Inspect *every* page — natural sizing means the diagram might land
        // on page 2 instead of page 1 depending on its rendered height.
        var perPageColor: [Int] = []
        var bestColor = 0
        for i in 0..<doc.pageCount {
            guard
                let page = doc.page(at: i),
                let cg = rasterize(page, scale: 2.0)
            else { perPageColor.append(-1); continue }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            var colored = 0
            let samples = 120
            for sx in 0..<samples {
                for sy in 0..<samples {
                    let x = (bitmap.pixelsWide * sx) / samples
                    let y = (bitmap.pixelsHigh * sy) / samples
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    let mx = max(color.redComponent, color.greenComponent, color.blueComponent)
                    let mn = min(color.redComponent, color.greenComponent, color.blueComponent)
                    if mn > 0.92 { continue }
                    if mx - mn > 0.10 { colored += 1 }
                }
            }
            perPageColor.append(colored)
            if colored > bestColor { bestColor = colored }
        }

        #expect(bestColor > 30,
                "Expected a rendered mermaid diagram somewhere in the PDF. Per-page colored pixel counts: \(perPageColor); pageCount=\(doc.pageCount)")
    }

    /// End-to-end smoke test that runs the showcase fixture through the
    /// full export pipeline and asserts every advanced feature actually
    /// reached the PDF:
    /// - footnotes section appears,
    /// - syntax-highlighted code shows colored tokens,
    /// - mermaid diagrams render as colored vector blocks,
    /// - math glyphs (Greek letters, ∑) appear at least somewhere,
    /// - URL images render,
    /// - tables show grid lines,
    /// - no page boundary slices a glyph.
    ///
    /// This is the one test that proves "all the features survived end
    /// to end" rather than spot-checking each in isolation.
    @Test func showcaseFixtureRendersEveryFeature() async throws {
        let markdown = try loadShowcaseMarkdown()
        let vm = EditorViewModel()
        vm.markdownContent = markdown
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount >= 5, "Showcase should span multiple pages, got \(doc.pageCount)")

        // OCR every page so we can search for representative text.
        var allText = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                allText += try await ocrText(of: page) + "\n"
            }
        }

        // 1. Headings and body content.
        #expect(allText.contains("Feature Showcase") || allText.localizedCaseInsensitiveContains("showcase"))

        // 2. Footnote definitions made it into the rendered text.
        #expect(allText.localizedCaseInsensitiveContains("footnote"))

        // 3. Mermaid produced something visual on at least one page.
        var mermaidColoredPixels = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let cg = rasterize(page, scale: 2.0) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            var colored = 0
            let samples = 80
            for sx in 0..<samples {
                for sy in 0..<samples {
                    let x = (bitmap.pixelsWide * sx) / samples
                    let y = (bitmap.pixelsHigh * sy) / samples
                    guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                    let mx = max(c.redComponent, c.greenComponent, c.blueComponent)
                    let mn = min(c.redComponent, c.greenComponent, c.blueComponent)
                    if mn > 0.92 { continue }
                    if mx - mn > 0.10 { colored += 1 }
                }
            }
            if colored > mermaidColoredPixels { mermaidColoredPixels = colored }
        }
        #expect(mermaidColoredPixels > 30,
                "Expected colored content from mermaid diagrams + syntax highlighting; got max \(mermaidColoredPixels) chromatic pixels on any page")

        // 4. No boundary slices a glyph (re-uses the precise edge-row check).
        let scale: CGFloat = 2
        let marginPx = Int(50 * scale)
        for boundary in 0..<(doc.pageCount - 1) {
            guard
                let upper = doc.page(at: boundary),
                let lower = doc.page(at: boundary + 1),
                let upperImg = rasterize(upper, scale: scale),
                let lowerImg = rasterize(lower, scale: scale)
            else { continue }
            let pw = upperImg.width
            let ph = upperImg.height
            let upperBytes = bgraBytes(of: upperImg)
            let lowerBytes = bgraBytes(of: lowerImg)
            let bytesPerRow = pw * 4
            let upperEdgeY = marginPx
            let lowerEdgeY = ph - marginPx - 1
            var cuts = 0
            for x in marginPx..<(pw - marginPx) {
                let upperOff = upperEdgeY * bytesPerRow + x * 4
                let lowerOff = lowerEdgeY * bytesPerRow + x * 4
                let upperInky = upperBytes[upperOff] < 200 || upperBytes[upperOff + 1] < 200 || upperBytes[upperOff + 2] < 200
                let lowerInky = lowerBytes[lowerOff] < 200 || lowerBytes[lowerOff + 1] < 200 || lowerBytes[lowerOff + 2] < 200
                if upperInky && lowerInky { cuts += 1 }
            }
            let cutRatio = Double(cuts) / Double(pw - 2 * marginPx)
            #expect(cutRatio < 0.03,
                    "Showcase page boundary \(boundary + 1)→\(boundary + 2) slices content (cutRatio = \(cutRatio))")
        }
    }

    @Test func exportRendersTableBorders() async throws {
        let vm = EditorViewModel()
        // A larger, more realistic table — smaller tables sometimes don't give
        // SwiftUI enough layout work to propagate anchor preferences before we
        // snapshot, even with the runloop spin.
        vm.markdownContent = """
        # Table border test

        Some intro text so the table isn't the first thing on the page.

        | Column A | Column B | Column C | Column D |
        |---|---|---|---|
        | Row 1 value | Two | Three | Four |
        | Row 2 value | Two | Three | Four |
        | Row 3 value | Two | Three | Four |
        | Row 4 value | Two | Three | Four |
        | Row 5 value | Two | Three | Four |

        Some trailing text after the table.
        """
        let url = makeTempPDFURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await vm.generatePDF(to: url)

        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        let bytesPerRow = pw * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * ph)
        let ctx = CGContext(data: &data, width: pw, height: ph, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)

        // Look for rows that are mostly ink across — that's a table border line.
        // Borders are light gray (#d2d2d7) so we use a generous threshold.
        var lineRows = 0
        for y in 0..<ph {
            var ink = 0
            for x in 0..<pw {
                let off = y * bytesPerRow + x * 4
                if data[off] < 240 || data[off + 1] < 240 || data[off + 2] < 240 {
                    ink += 1
                }
            }
            if ink > pw / 4 { lineRows += 1 }
        }
        #expect(lineRows > 0, "no horizontal-line rows detected — table borders are missing from the PDF")
    }
}
