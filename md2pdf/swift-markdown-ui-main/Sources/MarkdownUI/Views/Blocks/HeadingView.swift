import SwiftUI

struct HeadingView: View {
  @Environment(\.theme.headings) private var headings
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace

  private let level: Int
  private let content: [InlineNode]

  init(level: Int, content: [InlineNode]) {
    self.level = level
    self.content = content
  }

  var body: some View {
    Group {
      if addPageSplitSpace {
        VStack(alignment: .leading, spacing: 0) {
          headingContent
          Color.clear.frame(height: 8)
        }
      } else {
        headingContent
      }
    }
    .id(content.renderPlainText().kebabCased())
  }

  private var headingContent: some View {
    headings[self.level - 1].makeBody(
      configuration: .init(
        label: .init(InlineText(self.content)),
        content: .init(block: .heading(level: self.level, content: self.content))
      )
    )
  }
}
