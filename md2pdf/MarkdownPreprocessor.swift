//
//  MarkdownPreprocessor.swift
//  md2pdf
//
//  Source-level transforms applied to the markdown before it reaches
//  MarkdownUI. Each transform takes a markdown string and returns a
//  modified one, so they can be chained in `process(_:)` below.
//
//  Why preprocess instead of extending MarkdownUI?
//  - MarkdownUI's parser tracks the CommonMark spec; it deliberately
//    doesn't handle GFM footnotes, LaTeX math, or fenced custom blocks
//    like ```mermaid.
//  - Source-level rewriting keeps these as pluggable layers that we
//    can swap out (or improve) without touching the vendored library.
//

import Foundation

enum MarkdownPreprocessor {

    /// Run every preprocessing pass on the markdown source, in order.
    /// Each pass is idempotent and self-contained, so the order is not
    /// load-bearing — but expanding footnotes last keeps the footnote
    /// section at the very end of the document.
    static func process(_ markdown: String) -> String {
        var output = markdown
        output = expandFootnotes(in: output)
        return output
    }

    // MARK: - Footnotes

    /// Converts GFM-style footnote references and definitions into rendered
    /// superscripts + a "Footnotes" section appended to the document.
    ///
    /// Input:
    ///
    ///     Some claim.[^source]
    ///
    ///     [^source]: Smith 2024, p. 42.
    ///
    /// Output:
    ///
    ///     Some claim.¹
    ///
    ///     ---
    ///
    ///     **Footnotes**
    ///
    ///     ¹ Smith 2024, p. 42.
    ///
    /// IDs are numbered in *first reference* order so the printed numbering
    /// matches the reading order, regardless of where definitions appear in
    /// the source. References to undefined IDs are left as plain text so
    /// the user can spot the typo in the rendered output.
    static func expandFootnotes(in markdown: String) -> String {
        // 1. Find every reference [^id] in order of first appearance.
        let refRegex = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
        let nsString = markdown as NSString
        let refMatches = refRegex.matches(in: markdown, range: NSRange(location: 0, length: nsString.length))

        var orderedIDs: [String] = []
        var seenIDs: Set<String> = []
        for match in refMatches {
            let id = nsString.substring(with: match.range(at: 1))
            if !seenIDs.contains(id) {
                seenIDs.insert(id)
                orderedIDs.append(id)
            }
        }
        guard !orderedIDs.isEmpty else { return markdown }

        // 2. Pull out every definition `[^id]: …` (start-of-line). A
        //    definition's text can span multiple lines until the next blank
        //    line or another definition / heading — but most real-world
        //    footnotes are single-line, so we only consume the first line
        //    here to keep behavior predictable.
        let defRegex = try! NSRegularExpression(
            pattern: #"^[ \t]*\[\^([^\]\s]+)\]:[ \t]*(.+?)[ \t]*$"#,
            options: [.anchorsMatchLines]
        )
        let defMatches = defRegex.matches(in: markdown, range: NSRange(location: 0, length: nsString.length))

        var definitions: [String: String] = [:]
        var defRanges: [NSRange] = []
        for match in defMatches {
            let id = nsString.substring(with: match.range(at: 1))
            let text = nsString.substring(with: match.range(at: 2))
            if definitions[id] == nil {
                definitions[id] = text
            }
            defRanges.append(match.range)
        }

        // 3. Strip definition lines out of the body (back-to-front so prior
        //    ranges stay valid).
        let bodyMutable = NSMutableString(string: markdown)
        for range in defRanges.sorted(by: { $0.location > $1.location }) {
            bodyMutable.deleteCharacters(in: range)
        }
        var body = bodyMutable as String

        // 4. Replace each [^id] reference with its superscript number.
        for (index, id) in orderedIDs.enumerated() {
            let number = index + 1
            let pattern = "\\[\\^" + NSRegularExpression.escapedPattern(for: id) + "\\]"
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            body = regex.stringByReplacingMatches(
                in: body, range: range, withTemplate: superscript(number)
            )
        }

        // 5. Collapse runs of 3+ newlines we may have created when removing
        //    definition lines that sat on their own paragraphs.
        let blankRunRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)
        let blankRange = NSRange(body.startIndex..<body.endIndex, in: body)
        body = blankRunRegex.stringByReplacingMatches(
            in: body, range: blankRange, withTemplate: "\n\n"
        )
        body = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        // 6. Append the footnotes section. Definitions for IDs that were
        //    never referenced are dropped; references to IDs that have no
        //    definition get a "[undefined]" stub so the omission is visible.
        var section = "\n\n---\n\n**Footnotes**\n\n"
        for (index, id) in orderedIDs.enumerated() {
            let number = index + 1
            let text = definitions[id] ?? "_[undefined footnote: \(id)]_"
            section += "\(superscript(number)) \(text)\n\n"
        }
        return body + section
    }

    /// Renders an integer using Unicode superscript digits. Used for
    /// footnote markers so we don't need any HTML in the output.
    private static func superscript(_ n: Int) -> String {
        let digits: [Character: Character] = [
            "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}",
            "3": "\u{00B3}", "4": "\u{2074}", "5": "\u{2075}",
            "6": "\u{2076}", "7": "\u{2077}", "8": "\u{2078}",
            "9": "\u{2079}",
        ]
        return String(String(n).compactMap { digits[$0] })
    }
}
