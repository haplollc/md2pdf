<div align="center">

<img src="docs/icon.png" alt="md2pdf" width="180" />

# md2pdf

**A native macOS app — and CLI — that turns Markdown into pixel-perfect PDFs.**

Live split-pane editor with an instant preview, plus a high-fidelity
exporter that gets the small things right: table borders, list bullets,
syntax-highlighted code, LaTeX math, Mermaid diagrams, remote images,
and page breaks that never slice a line of text or an image in half.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue?style=flat-square&logo=swift)](https://developer.apple.com/swiftui/)
[![Markdown engine](https://img.shields.io/badge/engine-haplollc%2FMarkdown-purple?style=flat-square)](https://github.com/haplollc/Markdown)
[![Tests](https://img.shields.io/badge/tests-18%20passing-brightgreen?style=flat-square)](#testing)

</div>

---

## Why

Most "Markdown → PDF" tools fall into two camps:

1. **Headless browsers** (Chrome/wkhtmltopdf) — heavy, slow, and the
   output never quite matches a native macOS document.
2. **Naïve `NSAttributedString` exporters** — fast but they lose
   tables, inline images, list styling, and routinely slice text in
   half at page breaks.

**md2pdf** takes a third path: it renders the *actual SwiftUI Markdown
view* (the same one in the preview pane) and paginates at the **block
level**, so the exported PDF matches what you see — exactly.

## Features

- ✍️ **Split editor** with a draggable divider (the split ratio is
  remembered between launches).
- 🎨 **DocC-style rendering** — headings, emphasis, lists, blockquotes,
  tables, links, and fenced code.
- 🌈 **Syntax highlighting** for Swift, JS/TS, Python, JSON, HTML, CSS,
  shell, and Ruby — a dependency-free tokenizer.
- ➗ **LaTeX math** — `$inline$` and `$$display$$` rendered to Unicode
  (Greek, ∑ ∫, super/subscripts, fractions, √).
- 📊 **Mermaid diagrams** — flowcharts, sequence, and state diagrams
  rendered via a bundled mermaid.js and embedded as images.
- 🔖 **Footnotes** — `[^id]` references + multi-line definitions,
  collected into a Footnotes section.
- 🖼 **Remote images** — `![alt](https://…)` downloaded and embedded at
  natural size.
- 📄 **Block-level pagination** — page breaks land between blocks; a
  line of text, an image, or a table is never sliced across pages.
- 📏 **Per-page scaling** — a page that almost fits one more block
  shrinks slightly to absorb it instead of leaving a half-empty page.
- 📂 **"Open With → md2pdf"** for `.md` files from Finder.

## Architecture

```
md2pdf (this repo)
├── md2pdf/                     SwiftUI macOS app
├── Packages/
│   ├── Markdown/               ← git submodule: haplollc/Markdown
│   │                             the SwiftUI Markdown rendering engine
│   └── MarkdownPDFKit/         local package: the PDF pipeline
│       ├── MarkdownPDFRenderer   preprocess → mermaid → paginate → PDF
│       ├── MarkdownPreprocessor  footnotes + LaTeX math
│       ├── MermaidRenderer       WKWebView → SVG snapshot
│       ├── SyntaxHighlighter     fenced-code tokenizer
│       └── md2pdf-cli            command-line front end
└── Fixtures/                   feature showcase + sample docs
```

The app and the CLI share **one** rendering engine (`MarkdownPDFKit`),
so they produce identical output. The Markdown renderer itself lives in
a separate repo — [haplollc/Markdown](https://github.com/haplollc/Markdown) —
and is consumed here as a submodule.

## Clone & build

```sh
git clone --recurse-submodules https://github.com/haplollc/md2pdf.git
cd md2pdf
open md2pdf.xcodeproj
```

Already cloned without `--recurse-submodules`? Pull the engine:

```sh
git submodule update --init --recursive
```

Requirements: macOS 13+, Xcode 16+, Swift 5.9.

## CLI

The same engine ships as a command-line tool — great for scripts, CI,
and batch conversion.

```sh
cd Packages/MarkdownPDFKit
swift run md2pdf-cli notes.md                 # → notes.pdf
swift run md2pdf-cli notes.md ~/out/notes.pdf # explicit output
swift run md2pdf-cli --features               # list supported Markdown
swift run md2pdf-cli --help
```

## Showcase

[`Fixtures/feature_showcase.md`](Fixtures/feature_showcase.md) is a
single document that exercises every feature — inline formatting, all
heading levels, nested lists, blockquotes, tables, code in several
languages, math, three Mermaid diagrams, footnotes, and remote images.
Open it in the app (or run it through the CLI) to see the renderer's
output end-to-end.

## Testing

`md2pdfTests` is a pixel/OCR safety net that runs the real fixtures
through the full export pipeline:

| Test | Catches |
| --- | --- |
| `exportProducesNonBlankPDF` | First-page OCR contains expected text |
| `exportPreservesPageOrder` | Title on page 1, trailer on the last |
| `exportPaginatesMultiplePagesForLongDocument` | Long docs span >1 page |
| `exportProducesVisuallyNonBlankPixels` | Every page has rendered ink |
| `exportRendersURLImage` | Remote image appears in the PDF |
| `exportRendersTableBorders` | Anchor-driven table grids resolve |
| `exportHighlightsCodeFences` | Code shows colored tokens |
| `mathPreprocessor` / `footnotePreprocessor` / `multiLineFootnoteHandling` | Math + footnote transforms |
| `exportRendersMermaidDiagram` / `mermaidRendererSmokeTest` | Mermaid renders |
| `exportDoesNotSplitLinesMidWord` | No glyph sliced at a page boundary |
| `exportDoesNotSplitImagesAcrossPages` | Images stay whole |
| `exportKeepsContentOutOfBottomMargin` | Nothing bleeds past the margin |
| `exportPacksPagesEfficiently` | Non-terminal pages fill ≥80% |
| `codeBlockAndBlockquoteRenderDifferently` | Code ≠ blockquote styling |

```sh
xcodebuild test -project md2pdf.xcodeproj -scheme md2pdf -destination 'platform=macOS'
```

## License & credits

- App + `MarkdownPDFKit`: © Haplo LLC.
- Markdown rendering: [haplollc/Markdown](https://github.com/haplollc/Markdown),
  a modified fork of [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) (MIT).
- Mermaid diagrams via [mermaid.js](https://mermaid.js.org); Markdown
  parsing via [swift-cmark](https://github.com/apple/swift-cmark).

Built with [Claude Code](https://claude.com/claude-code).
