<div align="center">

<img src="docs/icon.png" alt="md2pdf" width="180" />

# md2pdf

**A native macOS app that turns Markdown into pixel-perfect PDFs.**

Live preview, resizable split editor, and a high-fidelity PDF exporter
that gets the small things right — table borders, list bullets,
images from URLs, and page breaks that never split a line of text.

[![macOS 15+](https://img.shields.io/badge/macOS-15.2%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-blue?style=flat-square&logo=swift)](https://developer.apple.com/swiftui/)
[![MarkdownUI](https://img.shields.io/badge/MarkdownUI-vendored-purple?style=flat-square)](https://github.com/gonzalezreal/swift-markdown-ui)
[![Tests](https://img.shields.io/badge/tests-10%20passing-brightgreen?style=flat-square)](#testing)

</div>

---

## Why

Most "markdown to PDF" tools fall into two camps:

1. **Headless browsers** that render HTML/CSS — heavy, slow, and the
   output never quite matches a real macOS document.
2. **Naive `NSAttributedString` exporters** — fast but lose tables,
   inline images, list styling, and frequently slice text mid-line at
   page breaks.

**md2pdf** takes a third path: it renders the actual `MarkdownUI` view
(the same one shown in the preview pane) and paginates at the *block
level*, so the exported PDF matches the on-screen render exactly.

## Features

- ✍️ **Live split editor** with a draggable divider — drag the center
  handle to expand either pane.
- 🎨 **DocC-style rendering** via [swift-markdown-ui], with full
  support for headings, bold/italic, lists, blockquotes, code fences,
  tables, and links.
- 📄 **Block-level pagination** — page breaks always land between
  blocks, never through a line of text or an image.
- 🖼 **URL-image rendering** — image references with `https://` URLs
  are pre-downloaded in parallel and embedded into the PDF.
- 📏 **Per-page scaling** — pages that almost fit one more block
  shrink slightly to absorb it, so you don't get half-empty pages.
- 📊 **Real table grids** — MarkdownUI's preference-driven table
  borders are correctly resolved before snapshotting (this is the
  thing most generic SwiftUI-to-PDF approaches silently drop).

## How it works

```
Markdown source
      │
      ▼
┌─────────────────────────┐
│ 1. Block split          │  CommonMark blocks: paragraphs, tables,
│    (lines / fences /    │     lists, code fences, images.
│     blank-line rule)    │
└─────────────────────────┘
      │
      ▼
┌─────────────────────────┐
│ 2. Preload remote       │  Regex `![alt](https://…)` → URLSession,
│    images               │     parallel download → in-memory cache.
└─────────────────────────┘
      │
      ▼
┌─────────────────────────┐
│ 3. Iterative pack       │  For each page, add blocks one at a time
│    + measure            │     and re-render the combined Markdown
│                         │     view to get the *actual* height.
│                         │     Back off when adding the next block
│                         │     would exceed the page limit.
└─────────────────────────┘
      │
      ▼
┌─────────────────────────┐
│ 4. Per-page snapshot    │  Each page is rendered as its OWN
│    (off-screen window,  │     Markdown view in an off-screen window
│     CALayer.render)     │     so MarkdownUI's anchor preferences
│                         │     (table borders, list bullets) resolve.
│                         │     CALayer rendered into a CG bitmap.
└─────────────────────────┘
      │
      ▼
┌─────────────────────────┐
│ 5. Compose PDF          │  Bitmap drawn into a CGPDFContext at
│                         │     per-page scale; consistent margins.
└─────────────────────────┘
      │
      ▼
   Final PDF
```

Because each page is a *complete, independent* MarkdownUI render,
slicing a glyph or splitting an image across pages is structurally
impossible — there's no shared bitmap that could be cut.

### Pagination tuning

Two constants in `EditorViewModel.Constants` control how dense pages get:

| Constant         | Default | Meaning                                            |
| ---------------- | ------- | -------------------------------------------------- |
| `viewScale`      | `0.82`  | Preferred (and max) text scale ≈ 11pt body         |
| `minViewScale`   | `0.70`  | Smallest per-page scale; cap on how tight a single page can pack ≈ 9pt body |

Pages whose content fits at `viewScale` render there. Pages that
*almost* fit one more block render at a per-page scale just small
enough to fit (down to `minViewScale`). Most pages look identical;
the occasional dense page renders slightly tighter.

## Testing

`md2pdfTests/md2pdfTests.swift` is the safety net. The pixel/OCR
tests run against the real fixture markdown
(`~/Desktop/europe_trip_with_activities.md`) so regressions can't hide
behind a synthetic input.

| Test                                       | Catches                                              |
| ------------------------------------------ | ---------------------------------------------------- |
| `exportProducesNonBlankPDF`                | First-page OCR contains expected source text         |
| `exportPreservesPageOrder`                 | OCR'd first page has title; last page has trailer    |
| `exportPaginatesMultiplePagesForLongDocument` | Long markdown produces >1 page                    |
| `exportProducesVisuallyNonBlankPixels`     | Every page has substantial rendered ink              |
| `exportRendersURLImage`                    | URL-loaded image actually appears in PDF             |
| `exportRendersTableBorders`                | Anchor-preference table grids resolve in snapshot    |
| `exportDoesNotSplitLinesMidWord`           | Glyphs never sliced across a page boundary           |
| `exportDoesNotSplitImagesAcrossPages`      | Photos always sit on one page                        |
| `exportKeepsContentOutOfBottomMargin`      | Nothing bleeds past the content area                 |
| `exportPacksPagesEfficiently`              | Non-terminal pages fill ≥80% of the content area     |

Run them with:

```sh
xcodebuild test -project md2pdf.xcodeproj -scheme md2pdf -destination 'platform=macOS'
```

## Build

Requirements: macOS 15.2+, Xcode 16+, Swift 6.

```sh
git clone <this repo>
cd md2pdf
open md2pdf.xcodeproj
```

MarkdownUI is vendored at `md2pdf/swift-markdown-ui-main/` as a
local Swift package — no `swift package resolve` needed.

## License & credits

- App: © Jared Cassoutt, all rights reserved.
- `swift-markdown-ui` is bundled under MIT (see `md2pdf/swift-markdown-ui-main/LICENSE`).

Built with [Claude Code].

[swift-markdown-ui]: https://github.com/gonzalezreal/swift-markdown-ui
[Claude Code]: https://claude.com/claude-code
