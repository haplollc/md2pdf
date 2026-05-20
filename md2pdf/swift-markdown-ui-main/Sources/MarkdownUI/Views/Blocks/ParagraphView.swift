import SwiftUI

struct ParagraphView: View {
  @Environment(\.theme.paragraph) private var paragraph
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace

  private let content: [InlineNode]

  init(content: String) {
    self.init(
      content: [
        .text(content.hasSuffix("\n") ? String(content.dropLast()) : content)
      ]
    )
  }

  init(content: [InlineNode]) {
    self.content = content
  }

  var body: some View {
    Group {
      if addPageSplitSpace {
        VStack(alignment: .leading, spacing: 0) {
          paragraphContent
          Color.clear.frame(height: 8) // Adds spacing to reduce chance of line-split on page breaks
        }
      } else {
        paragraphContent
      }
    }
  }

  private var paragraphContent: some View {
    self.paragraph.makeBody(
      configuration: .init(
        label: .init(self.label),
        content: .init(block: .paragraph(content: self.content))
      )
    )
  }

  @ViewBuilder private var label: some View {
    if let imageView = ImageView(content) {
      imageView
    } else if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *),
              let imageFlow = ImageFlow(content) {
      imageFlow
    } else {
      InlineText(content)
    }
  }
}
