import SwiftUI

struct CodeBlockView: View {
  // Use the proper `codeBlock` theme entry (gray bg + monospaced) instead
  // of `blockquote` (rounded aside-box). Reading `blockquote` here was the
  // long-standing reason fenced code blocks and real `>` quotes rendered
  // identically.
  @Environment(\.theme.codeBlock) private var codeBlockStyle
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace
  @Environment(\.codeSyntaxHighlighter) private var codeSyntaxHighlighter

  private let fenceInfo: String?
  private let content: String

  init(fenceInfo: String?, content: String) {
    self.fenceInfo = fenceInfo
    self.content = content.hasSuffix("\n") ? String(content.dropLast()) : content
  }

  var body: some View {
    Group {
      if addPageSplitSpace {
        VStack(alignment: .leading, spacing: 0) {
          codeBlockContent
          Color.clear.frame(height: 8)
        }
      } else {
        codeBlockContent
      }
    }
  }

  private var codeBlockContent: some View {
    self.codeBlockStyle.makeBody(
      configuration: .init(
        language: self.fenceInfo,
        content: self.content,
        label: .init(self.label)
      )
    )
  }

  private var label: some View {
    // Hand the highlighter the raw source — the theme provides padding,
    // background, font family, etc. We deliberately don't apply our own
    // font here so the docC theme's `FontFamilyVariant(.monospaced)` /
    // `FontSize(.rem(0.88235))` win.
    codeSyntaxHighlighter.highlightCode(self.content, language: self.fenceInfo)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
