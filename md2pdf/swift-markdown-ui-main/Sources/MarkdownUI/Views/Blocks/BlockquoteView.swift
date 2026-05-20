import SwiftUI

struct BlockquoteView: View {
  @Environment(\.theme.blockquote) private var blockquote
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace

  private let children: [BlockNode]

  init(children: [BlockNode]) {
    self.children = children
  }

  var body: some View {
    Group {
      if addPageSplitSpace {
        VStack(alignment: .leading, spacing: 0) {
          blockquoteContent
          Color.clear.frame(height: 8)
        }
      } else {
        blockquoteContent
      }
    }
  }

  private var blockquoteContent: some View {
    self.blockquote.makeBody(
      configuration: .init(
        label: .init(BlockSequence(self.children)),
        content: .init(block: .blockquote(children: self.children))
      )
    )
  }
}
