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

    /// Run every synchronous preprocessing pass on the markdown source.
    /// Math is expanded *before* footnotes so a `$x^{[1]}$`-style expression
    /// never collides with footnote-reference syntax.
    static func process(_ markdown: String) -> String {
        var output = markdown
        output = renderMath(in: output)
        output = expandFootnotes(in: output)
        return output
    }

    // MARK: - Mermaid extraction

    /// Returns every fenced ```mermaid block's source code, in document order.
    /// Used by the export pipeline to feed the WKWebView-based renderer.
    static func extractMermaid(_ markdown: String) -> [String] {
        let regex = try! NSRegularExpression(
            pattern: #"```mermaid\s*\n([\s\S]+?)\n```"#,
            options: []
        )
        let ns = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Replaces every ```mermaid block with a markdown image reference
    /// pointing at the URL we generated for its rendered diagram. Blocks
    /// whose rendering failed (URL missing in the map) are left as
    /// fenced code so the user can still see the source.
    static func replaceMermaid(in markdown: String, withImageURLs urls: [String: URL]) -> String {
        let regex = try! NSRegularExpression(
            pattern: #"```mermaid\s*\n([\s\S]+?)\n```"#
        )
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: markdown)
        for match in matches.reversed() {
            let code = ns.substring(with: match.range(at: 1))
            if let url = urls[code] {
                mutable.replaceCharacters(in: match.range, with: "![Mermaid diagram](\(url.absoluteString))")
            }
        }
        return mutable as String
    }

    // MARK: - Math (Unicode substitution renderer)

    /// Rewrites `$inline$` and `$$display$$` LaTeX math into Unicode
    /// approximations that MarkdownUI can render natively. This is a
    /// *light* renderer — it gets Greek letters, common symbols, simple
    /// super/subscripts, and basic fractions right, which covers the
    /// majority of casual math in technical writing. For full KaTeX-grade
    /// fidelity we'd need to bundle KaTeX + a WKWebView snapshotter; that's
    /// scoped as a follow-up.
    static func renderMath(in markdown: String) -> String {
        var output = markdown
        // Display math `$$ … $$` → centered italic on its own line.
        let displayRegex = try! NSRegularExpression(
            pattern: #"\$\$((?:[^$]|\\\$)+?)\$\$"#,
            options: [.dotMatchesLineSeparators]
        )
        output = replaceMatches(in: output, regex: displayRegex) { latex in
            let rendered = transformLatex(latex.trimmingCharacters(in: .whitespacesAndNewlines))
            return "\n\n*\(rendered)*\n\n"
        }
        // Inline math `$ … $` — single dollar pairs, no newlines.
        let inlineRegex = try! NSRegularExpression(
            pattern: #"\$((?:[^$\n]|\\\$)+?)\$"#
        )
        output = replaceMatches(in: output, regex: inlineRegex) { latex in
            transformLatex(latex)
        }
        return output
    }

    /// Apply a `(latex: String) -> String` replacement function across every
    /// regex match in the source. Walks back-to-front so prior match ranges
    /// stay valid after each substitution.
    private static func replaceMatches(
        in source: String,
        regex: NSRegularExpression,
        with transform: (String) -> String
    ) -> String {
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: source)
        for match in matches.reversed() {
            let captured = ns.substring(with: match.range(at: 1))
            mutable.replaceCharacters(in: match.range, with: transform(captured))
        }
        return mutable as String
    }

    /// Apply LaTeX → Unicode substitutions:
    /// 1. Greek letters (`\alpha` → α, `\Sigma` → Σ, …).
    /// 2. Common operators (`\sum` → ∑, `\int` → ∫, `\to` → →, …).
    /// 3. `^{…}` and `^x` superscripts.
    /// 4. `_{…}` and `_x` subscripts.
    /// 5. `\frac{a}{b}` → `a / b` (rendered linearly, the cleanest option
    ///    without true math typesetting).
    /// 6. `\sqrt{x}` → `√x`.
    static func transformLatex(_ latex: String) -> String {
        var s = latex
        // \frac{a}{b} — handle nested braces shallowly.
        let fracRegex = try! NSRegularExpression(pattern: #"\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}"#)
        s = replaceTwoCapture(in: s, regex: fracRegex) { num, den in
            "(\(num)) / (\(den))"
        }
        // \sqrt{x}
        let sqrtRegex = try! NSRegularExpression(pattern: #"\\sqrt\s*\{([^{}]+)\}"#)
        s = replaceMatches(in: s, regex: sqrtRegex) { x in
            "√(\(x))"
        }
        // Greek letters & symbols (longest-name-first so `\alpha` matches before `\al`).
        for (cmd, glyph) in latexGlyphs {
            s = s.replacingOccurrences(of: cmd, with: glyph)
        }
        // Superscripts: `^{abc}` and single-token `^a`.
        s = applyScript(in: s, marker: "^", map: superscriptMap)
        // Subscripts: `_{abc}` and single-token `_a`.
        s = applyScript(in: s, marker: "_", map: subscriptMap)
        // Collapse `\left(` / `\right)` etc.
        s = s.replacingOccurrences(of: "\\left", with: "")
        s = s.replacingOccurrences(of: "\\right", with: "")
        // Collapse stray braces left behind by partial matches.
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")
        return s
    }

    /// `marker` is `^` or `_`. Handles both `^{abc}` (apply to all of abc)
    /// and `^a` (single char/token). Unicode super/subscript maps cover
    /// digits and most ASCII letters — characters outside the map fall back
    /// to the original character so we never silently lose content.
    private static func applyScript(
        in source: String,
        marker: Character,
        map: [Character: Character]
    ) -> String {
        var output = ""
        var i = source.startIndex
        while i < source.endIndex {
            if source[i] == marker, source.index(after: i) < source.endIndex {
                let next = source.index(after: i)
                if source[next] == "{" {
                    // Find matching `}`.
                    if let close = source[next...].firstIndex(of: "}") {
                        let inside = source[source.index(after: next)..<close]
                        output += String(inside).map { map[$0] ?? $0 }.map { String($0) }.joined()
                        i = source.index(after: close)
                        continue
                    }
                } else {
                    // Single-character form.
                    let ch = source[next]
                    output += String(map[ch] ?? ch)
                    i = source.index(after: next)
                    continue
                }
            }
            output.append(source[i])
            i = source.index(after: i)
        }
        return output
    }

    private static func replaceTwoCapture(
        in source: String,
        regex: NSRegularExpression,
        with transform: (String, String) -> String
    ) -> String {
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: source)
        for match in matches.reversed() {
            let a = ns.substring(with: match.range(at: 1))
            let b = ns.substring(with: match.range(at: 2))
            mutable.replaceCharacters(in: match.range, with: transform(a, b))
        }
        return mutable as String
    }

    // MARK: - Symbol tables for math transform

    /// LaTeX command → Unicode glyph. Sorted longest-command-first inside
    /// the closure that iterates this so `\alpha` matches before `\al`.
    private static let latexGlyphs: [(String, String)] = {
        let raw: [String: String] = [
            // Lowercase Greek
            "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
            "\\epsilon": "ε", "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η",
            "\\theta": "θ", "\\vartheta": "ϑ", "\\iota": "ι", "\\kappa": "κ",
            "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ",
            "\\pi": "π", "\\varpi": "ϖ", "\\rho": "ρ", "\\varrho": "ϱ",
            "\\sigma": "σ", "\\varsigma": "ς", "\\tau": "τ", "\\upsilon": "υ",
            "\\phi": "ϕ", "\\varphi": "φ", "\\chi": "χ", "\\psi": "ψ",
            "\\omega": "ω",
            // Uppercase Greek
            "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
            "\\Xi": "Ξ", "\\Pi": "Π", "\\Sigma": "Σ", "\\Upsilon": "Υ",
            "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
            // Operators / relations
            "\\times": "×", "\\div": "÷", "\\pm": "±", "\\mp": "∓",
            "\\cdot": "·", "\\cdots": "⋯", "\\ldots": "…", "\\dots": "…",
            "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈",
            "\\equiv": "≡", "\\sim": "∼", "\\propto": "∝", "\\infty": "∞",
            "\\partial": "∂", "\\nabla": "∇", "\\forall": "∀", "\\exists": "∃",
            "\\in": "∈", "\\notin": "∉", "\\subset": "⊂", "\\supset": "⊃",
            "\\subseteq": "⊆", "\\supseteq": "⊇", "\\cup": "∪", "\\cap": "∩",
            "\\emptyset": "∅",
            // Big operators
            "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\oint": "∮",
            "\\iint": "∬", "\\iiint": "∭",
            // Arrows
            "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←",
            "\\Rightarrow": "⇒", "\\Leftarrow": "⇐", "\\leftrightarrow": "↔",
            "\\Leftrightarrow": "⇔", "\\mapsto": "↦",
            // Misc
            "\\degree": "°", "\\angle": "∠", "\\perp": "⊥", "\\parallel": "∥",
            "\\therefore": "∴", "\\because": "∵",
            "\\hbar": "ℏ", "\\ell": "ℓ", "\\Re": "ℜ", "\\Im": "ℑ",
            "\\\\": "\n",  // line break in display math
        ]
        // Sort by command length descending — guarantees `\alpha` is tried
        // before `\al`, `\Leftrightarrow` before `\Left`, etc.
        return raw.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
    }()

    private static let superscriptMap: [Character: Character] = [
        "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
        "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
        "8": "\u{2078}", "9": "\u{2079}",
        "+": "\u{207A}", "-": "\u{207B}", "=": "\u{207C}",
        "(": "\u{207D}", ")": "\u{207E}", "n": "\u{207F}",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ",
        "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "\u{2080}", "1": "\u{2081}", "2": "\u{2082}", "3": "\u{2083}",
        "4": "\u{2084}", "5": "\u{2085}", "6": "\u{2086}", "7": "\u{2087}",
        "8": "\u{2088}", "9": "\u{2089}",
        "+": "\u{208A}", "-": "\u{208B}", "=": "\u{208C}",
        "(": "\u{208D}", ")": "\u{208E}",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

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
