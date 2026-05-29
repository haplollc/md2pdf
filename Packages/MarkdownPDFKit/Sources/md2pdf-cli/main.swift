//
//  md2pdf-cli
//
//  Command-line front end for MarkdownPDFKit. Converts a Markdown file
//  into a paginated PDF using the same engine as the md2pdf macOS app.
//
//  Usage:
//    md2pdf-cli <input.md> [output.pdf]
//    md2pdf-cli --features
//    md2pdf-cli --help
//

import Foundation
import AppKit
import MarkdownPDFKit

// MARK: - Help / features text

let toolName = "md2pdf-cli"

func printUsage() {
    print("""
    \(toolName) — convert Markdown to a paginated PDF

    USAGE
      \(toolName) <input.md> [output.pdf]
      \(toolName) --features
      \(toolName) --help

    ARGUMENTS
      <input.md>     Path to the Markdown file to convert.
      [output.pdf]   Where to write the PDF. Defaults to the input path
                     with its extension replaced by .pdf.

    OPTIONS
      --features     Print the Markdown features this tool supports.
      -h, --help     Show this help.

    EXAMPLES
      \(toolName) notes.md
      \(toolName) notes.md ~/Desktop/notes.pdf
    """)
}

func printFeatures() {
    print("""
    \(toolName) renders GitHub-flavored Markdown to PDF with:

    TEXT
      • Headings (h1–h6) with a sized hierarchy
      • Bold, italic, bold-italic, inline code, strikethrough
      • Links

    STRUCTURE
      • Ordered, unordered, and task lists (nested)
      • Block quotes (nested)
      • Tables with alignment + visible borders
      • Thematic breaks (---)
      • Horizontal-rule separators

    CODE
      • Fenced code blocks with syntax highlighting for
        Swift, JavaScript/TypeScript, Python, JSON, HTML, CSS,
        shell, and Ruby. Unknown languages render as plain monospace.

    RICH CONTENT
      • Images — local paths AND remote https URLs (downloaded and
        embedded at natural size).
      • Mermaid diagrams — ```mermaid flowchart / sequence / state /
        etc. rendered to vector-quality images.
      • LaTeX math — $inline$ and $$display$$ converted to Unicode
        (Greek letters, ∑ ∫, super/subscripts, fractions, √).
      • Footnotes — [^id] references + multi-line [^id]: definitions,
        collected into a Footnotes section.

    PAGINATION
      • Block-level page breaks: a line of text, an image, or a table
        is never sliced across a page boundary.
      • Per-page scaling: a page that almost fits one more block shrinks
        slightly to absorb it instead of leaving a half-empty page.
      • A4 pages, 50pt margins.
    """)
}

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.contains("-h") || args.contains("--help") {
    printUsage()
    exit(args.isEmpty ? 1 : 0)
}

if args.contains("--features") {
    printFeatures()
    exit(0)
}

let inputPath = args[0]
let inputURL = URL(fileURLWithPath: inputPath)

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    FileHandle.standardError.write(Data("error: no such file: \(inputPath)\n".utf8))
    exit(1)
}

let outputURL: URL
if args.count >= 2 {
    outputURL = URL(fileURLWithPath: args[1])
} else {
    outputURL = inputURL.deletingPathExtension().appendingPathExtension("pdf")
}

guard let markdown = try? String(contentsOf: inputURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("error: could not read \(inputPath)\n".utf8))
    exit(1)
}

// MARK: - Run

// MarkdownPDFKit drives NSHostingView + WKWebView, which need a running
// NSApplication + main run loop. Spin one up in accessory mode (no Dock
// icon, no menu bar), do the work on the main actor, then exit.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Runner: NSObject {
    let markdown: String
    let output: URL
    init(markdown: String, output: URL) {
        self.markdown = markdown
        self.output = output
    }

    @MainActor
    func run() async {
        await MarkdownPDFRenderer.render(markdown: markdown, to: output)
        if FileManager.default.fileExists(atPath: output.path) {
            print("Wrote \(output.path)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("error: failed to write PDF\n".utf8))
            exit(1)
        }
    }
}

let runner = Runner(markdown: markdown, output: outputURL)
Task { @MainActor in
    await runner.run()
}
app.run()
