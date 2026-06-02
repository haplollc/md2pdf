//
//  Theme+md2pdf.swift
//  MarkdownPDFKit
//
//  The app's shared MarkdownUI theme. It's the DocC theme, but code blocks
//  WRAP long lines instead of scrolling horizontally — so code fits the
//  column on a narrow iPhone instead of forcing a horizontal scroll, and the
//  live preview matches the exported PDF (which can't scroll, it just clips).
//  Using one theme for both the preview and the renderer keeps them identical.
//

import SwiftUI
import Markdown

public extension Theme {
    static var md2pdf: Theme {
        Theme.docC.codeBlock { configuration in
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
}
