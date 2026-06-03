//
//  Theme+md2pdf.swift
//  MarkdownPDFKit
//
//  The app's shared MarkdownUI theme. It's the DocC theme with two changes:
//
//    1. Code blocks WRAP long lines instead of scrolling horizontally — so
//       code fits the column on a narrow iPhone instead of forcing a
//       horizontal scroll, and the live preview matches the exported PDF
//       (which can't scroll, it just clips).
//
//    2. ```mermaid blocks are rendered as their pre-rendered diagram image
//       *through the code-block style* — i.e. as an ordinary SwiftUI image in
//       the normal block flow — instead of being rewritten into a Markdown
//       image reference. This matters: MarkdownUI's block-image layout
//       (`ImageFlow`/`FlowLayout`) ignores width constraints and clips wide
//       diagrams, whereas a plain `Image().resizable().scaledToFit()` honours
//       the proposed column width on every render path and device. That's why
//       the diagrams now always shrink to fit and never crop — no per-path
//       raster-scale fudging required.
//
//  Using one theme for both the preview and the renderer keeps them identical.
//

import SwiftUI
import Markdown

// MARK: - Mermaid image environment

/// Pre-rendered mermaid diagram bitmaps, keyed by their trimmed mermaid
/// source. The renderer injects this so the `codeBlock` style can look up the
/// image for a given ```mermaid block. (Read inside a `View` — the block-style
/// closure itself isn't an `@Environment` context.)
private struct MermaidImagesKey: EnvironmentKey {
    static let defaultValue: [String: PlatformImage] = [:]
}

extension EnvironmentValues {
    var mermaidImages: [String: PlatformImage] {
        get { self[MermaidImagesKey.self] }
        set { self[MermaidImagesKey.self] = newValue }
    }
}

public extension View {
    /// Makes pre-rendered mermaid diagrams available to the `md2pdf` theme.
    /// Key each image by its trimmed mermaid source.
    func mermaidImages(_ images: [String: PlatformImage]) -> some View {
        environment(\.mermaidImages, images)
    }
}

// MARK: - Code-block style (code or mermaid diagram)

/// The `md2pdf` code-block body. For a ```mermaid block with a rendered image
/// available it shows the diagram scaled to fit the column; otherwise (any
/// other language, or a mermaid block whose render failed) it shows the
/// wrapped, panel-styled source.
private struct MD2PDFCodeBlock: View {
    @Environment(\.mermaidImages) private var mermaidImages
    let configuration: CodeBlockConfiguration

    private var mermaidImage: PlatformImage? {
        guard (configuration.language ?? "").lowercased() == "mermaid" else { return nil }
        return mermaidImages[configuration.content.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    var body: some View {
        if let image = mermaidImage {
            // NON-resizable on purpose: the image was already sized to fit the
            // column (at scale 1) by the renderer, so the off-screen render
            // draws it 1:1 at its point size. A resizable image would let the
            // off-screen render scale it by the bitmap's pixel size and clip.
            Image(platformImage: image)
                .frame(maxWidth: .infinity, alignment: .center)
                .markdownMargin(top: .em(0.8), bottom: .em(0.8))
        } else {
            sourceBlock
        }
    }

    private var sourceBlock: some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.333335))
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(.rem(0.88235))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Secondary fill (matches the DocC light code background) so the
            // block reads as a panel against the white page.
            .background(Color(red: 0.910, green: 0.910, blue: 0.929))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .markdownMargin(top: .em(0.8), bottom: .zero)
    }
}

public extension Theme {
    static var md2pdf: Theme {
        Theme.docC.codeBlock { configuration in
            MD2PDFCodeBlock(configuration: configuration)
        }
    }
}
