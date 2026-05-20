import SwiftUI

struct ThematicBreakView: View {
  @Environment(\.theme.thematicBreak) private var thematicBreak
  @Environment(\.addPageSplitSpace) private var addPageSplitSpace

  var body: some View {
    Group {
      if addPageSplitSpace {
        VStack(alignment: .leading, spacing: 0) {
          thematicBreak.makeBody(configuration: ())
          Color.clear.frame(height: 8)
        }
      } else {
        thematicBreak.makeBody(configuration: ())
      }
    }
  }
}
