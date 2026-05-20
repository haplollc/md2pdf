import SwiftUI

extension Sequence where Element == InlineNode {
  func renderText(
    addPageSplitSpace: Bool,
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) -> Text {
    var renderer = TextInlineRenderer(
      addPageSplitSpace: addPageSplitSpace,  // ← Pass Bool here
      baseURL: baseURL,
      textStyles: textStyles,
      images: images,
      softBreakMode: softBreakMode,
      attributes: attributes
    )
    renderer.render(self)
    return renderer.result
  }
}

private struct TextInlineRenderer {
  // MARK: - Public result
  var result = Text("")

  // MARK: - Private stored properties
  private let addPageSplitSpace: Bool
  private let baseURL: URL?
  private let textStyles: InlineTextStyles
  private let images: [String: Image]
  private let softBreakMode: SoftBreak.Mode
  private let attributes: AttributeContainer
  private var shouldSkipNextWhitespace = false

  // MARK: - Initializer
  init(
    addPageSplitSpace: Bool,
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) {
    self.addPageSplitSpace = addPageSplitSpace
    self.baseURL = baseURL
    self.textStyles = textStyles
    self.images = images
    self.softBreakMode = softBreakMode
    self.attributes = attributes
  }

  // MARK: - Render sequence
  mutating func render<S: Sequence>(_ inlines: S) where S.Element == InlineNode {
    for inline in inlines {
      self.render(inline)
    }
  }

  // MARK: - Render single InlineNode
  private mutating func render(_ inline: InlineNode) {
    switch inline {
    case .text(let content):
      self.renderText(content)
    case .softBreak:
      self.renderSoftBreak()
    case .html(let content):
      self.renderHTML(content)
    case .image(let source, _):
      self.renderImage(source)
    default:
      self.defaultRender(inline)
    }
  }

  // MARK: - Specific inline handlers
  private mutating func renderText(_ text: String) {
    var text = text

    // If we asked to skip whitespace (after a forced line break), remove leading spaces
    if self.shouldSkipNextWhitespace {
      self.shouldSkipNextWhitespace = false
      text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
    }

    self.defaultRender(.text(text))
  }

  private mutating func renderSoftBreak() {
    switch self.softBreakMode {
    case .space where self.shouldSkipNextWhitespace:
      // Just skip the next whitespace, do nothing else
      self.shouldSkipNextWhitespace = false

    case .space:
      // If addPageSplitSpace, inject extra vertical offset; otherwise a normal soft break
      if self.addPageSplitSpace {
        // Could do baseline offset or add extra newline. Here’s a simple offset:
        self.result = self.result + Text("\n").baselineOffset(8)
      } else {
        self.defaultRender(.softBreak)
      }

    case .lineBreak:
      // Hard break → skip whitespace after the break
      self.shouldSkipNextWhitespace = true

      if self.addPageSplitSpace {
        // Insert a line break plus vertical offset
        self.result = self.result + Text("\n").baselineOffset(8)
      } else {
        self.defaultRender(.lineBreak)
      }
    }
  }

  private mutating func renderHTML(_ html: String) {
    let tag = HTMLTag(html)
    switch tag?.name.lowercased() {
    case "br":
      // <br /> → treat as a lineBreak
      self.defaultRender(.lineBreak)
      self.shouldSkipNextWhitespace = true
    default:
      self.defaultRender(.html(html))
    }
  }

  private mutating func renderImage(_ source: String) {
    if let image = self.images[source] {
      // Combine existing Text with an Image
      self.result = self.result + Text(image)
    }
  }

  // MARK: - Fallback rendering
  private mutating func defaultRender(_ inline: InlineNode) {
    self.result =
      self.result
      + Text(
        inline.renderAttributedString(
          addPageSplitSpace: self.addPageSplitSpace,
          baseURL: self.baseURL,
          textStyles: self.textStyles,
          softBreakMode: self.softBreakMode,
          attributes: self.attributes
        )
      )
  }
}
