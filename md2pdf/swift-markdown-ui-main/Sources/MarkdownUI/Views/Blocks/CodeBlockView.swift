import SwiftUI

struct CodeBlockView: View {
  @Environment(\.theme.blockquote) private var blockquote
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace

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
    self.blockquote.makeBody(
      configuration: .init(
        label: .init(self.label),
        content: .init(block: .blockquote(children: [
          .paragraph(content: [.text(self.content)])
        ]))
      )
    )
  }

  private var label: some View {
    Text(self.content)
      .font(.system(.body, design: .monospaced))
      .foregroundColor(.primary)
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
