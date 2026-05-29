//
//  SyntaxHighlighter.swift
//  md2pdf
//
//  Lightweight, dependency-free code highlighter that plugs into
//  MarkdownUI via the `CodeSyntaxHighlighter` protocol.
//
//  We deliberately don't pull in Splash or Highlightr — Splash is
//  Swift-only, Highlightr drags in JavaScriptCore. Neither was worth
//  the maintenance burden for the small set of languages markdown
//  documents actually need to highlight on a regular basis.
//
//  The grammar is intentionally shallow: it gets keywords, strings,
//  numbers, and comments right, which covers ~95% of what users want
//  in a printed code listing. Full lexer accuracy isn't a goal here.
//

import SwiftUI
import Markdown

public struct SyntaxHighlighter: CodeSyntaxHighlighter {
    public init() {}

    public func highlightCode(_ code: String, language: String?) -> Text {
        guard
            let lang = language?.lowercased(),
            let grammar = Grammar.grammars[lang]
        else {
            return Text(code)
        }
        return tokenize(code, with: grammar)
            .reduce(Text("")) { acc, token in
                acc + token.styled()
            }
    }
}

// MARK: - Tokens

private enum TokenKind {
    case plain, keyword, type, string, number, comment

    var color: Color {
        switch self {
        case .plain:   return .primary
        case .keyword: return Color(red: 0.78, green: 0.19, blue: 0.49) // magenta-ish
        case .type:    return Color(red: 0.16, green: 0.43, blue: 0.66) // blue
        case .string:  return Color(red: 0.78, green: 0.22, blue: 0.22) // red-orange
        case .number:  return Color(red: 0.16, green: 0.43, blue: 0.66) // blue
        case .comment: return Color(.sRGB, white: 0.45, opacity: 1)     // gray
        }
    }
}

private struct Token {
    let text: String
    let kind: TokenKind
    func styled() -> Text { Text(text).foregroundColor(kind.color) }
}

// MARK: - Grammar table

private struct Grammar {
    /// `//` for C-like languages, `#` for Python/shell/Ruby/etc., nil if unsupported.
    let lineComment: String?
    /// `/* … */` style block comments.
    let blockComment: (open: String, close: String)?
    /// String delimiters (`"`, `'`, `` ` ``).
    let stringDelimiters: [Character]
    /// Allow multi-line strings (Python `"""…"""`, Swift `""" … """`).
    let tripleStringDelimiters: [Character]
    /// Reserved words; styled as `keyword`.
    let keywords: Set<String>
    /// Words that look like type names (start uppercase) get the `type` color
    /// when this flag is on. Swift/JS/etc. — off for shell.
    let typeByCapitalization: Bool

    static let grammars: [String: Grammar] = [
        "swift":      .swift,
        "js":         .javascript, "javascript": .javascript, "ts": .javascript, "typescript": .javascript,
        "python":     .python, "py": .python,
        "json":       .json,
        "html":       .html, "xml": .html,
        "css":        .css,
        "sh":         .shell, "bash": .shell, "shell": .shell, "zsh": .shell,
        "ruby":       .ruby, "rb": .ruby,
    ]

    static let swift = Grammar(
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        tripleStringDelimiters: ["\""],
        keywords: [
            "import","let","var","func","return","if","else","guard","switch","case","default",
            "for","while","repeat","do","try","catch","throw","throws","rethrows","async","await",
            "struct","class","enum","protocol","extension","init","deinit","self","Self","super",
            "public","private","fileprivate","internal","open","static","final","lazy","weak","unowned",
            "true","false","nil","in","as","is","where","break","continue","fallthrough","defer",
            "associatedtype","typealias","subscript","get","set","willSet","didSet","mutating","nonmutating",
            "indirect","operator","precedencegroup","inout","some","any","actor","convenience","required",
        ],
        typeByCapitalization: true
    )

    static let javascript = Grammar(
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        tripleStringDelimiters: [],
        keywords: [
            "const","let","var","function","return","if","else","switch","case","default",
            "for","while","do","break","continue","class","extends","super","this","new",
            "import","export","from","as","async","await","try","catch","finally","throw",
            "true","false","null","undefined","typeof","instanceof","in","of","delete","void",
            "yield","static","get","set",
            "interface","type","enum","public","private","protected","readonly","implements","abstract",
        ],
        typeByCapitalization: true
    )

    static let python = Grammar(
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        tripleStringDelimiters: ["\"", "'"],
        keywords: [
            "def","class","return","if","elif","else","for","while","break","continue",
            "import","from","as","try","except","finally","raise","with","yield","lambda",
            "True","False","None","and","or","not","is","in","pass","global","nonlocal",
            "async","await","assert","del","self",
        ],
        typeByCapitalization: true
    )

    static let json = Grammar(
        lineComment: nil,
        blockComment: nil,
        stringDelimiters: ["\""],
        tripleStringDelimiters: [],
        keywords: ["true","false","null"],
        typeByCapitalization: false
    )

    static let html = Grammar(
        lineComment: nil,
        blockComment: ("<!--", "-->"),
        stringDelimiters: ["\"", "'"],
        tripleStringDelimiters: [],
        keywords: [],
        typeByCapitalization: false
    )

    static let css = Grammar(
        lineComment: nil,
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        tripleStringDelimiters: [],
        keywords: [
            "important","inherit","initial","unset","auto","none",
        ],
        typeByCapitalization: false
    )

    static let shell = Grammar(
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        tripleStringDelimiters: [],
        keywords: [
            "if","then","else","elif","fi","for","while","do","done","case","esac","in",
            "function","return","exit","echo","cd","export","local","read","source",
            "true","false",
        ],
        typeByCapitalization: false
    )

    static let ruby = Grammar(
        lineComment: "#",
        blockComment: ("=begin", "=end"),
        stringDelimiters: ["\"", "'"],
        tripleStringDelimiters: [],
        keywords: [
            "def","end","class","module","if","elsif","else","unless","while","until","do",
            "begin","rescue","ensure","raise","return","yield","lambda","proc","self","nil",
            "true","false","require","require_relative","attr_accessor","attr_reader","attr_writer",
            "puts","print","include","extend","new","initialize","super","then",
        ],
        typeByCapitalization: true
    )
}

// MARK: - Tokenizer

/// Walks the source from left to right. At each position, tries (in order):
/// triple-string, line comment, block comment, single-line string, number,
/// identifier (keyword/type/plain). When nothing matches, emits one plain
/// character and advances by one — preserves whitespace and exotic glyphs.
private func tokenize(_ code: String, with grammar: Grammar) -> [Token] {
    var tokens: [Token] = []
    var plainBuf = ""

    func flushPlain() {
        if !plainBuf.isEmpty {
            tokens.append(Token(text: plainBuf, kind: .plain))
            plainBuf = ""
        }
    }

    let scalars = Array(code)
    var i = 0

    while i < scalars.count {
        // Triple-quoted strings (Python """ / ''')
        if let delim = grammar.tripleStringDelimiters.first(where: { d in
            i + 2 < scalars.count && scalars[i] == d && scalars[i + 1] == d && scalars[i + 2] == d
        }) {
            flushPlain()
            let start = i
            i += 3
            while i + 2 < scalars.count,
                  !(scalars[i] == delim && scalars[i + 1] == delim && scalars[i + 2] == delim) {
                i += 1
            }
            i = min(scalars.count, i + 3)
            tokens.append(Token(text: String(scalars[start..<i]), kind: .string))
            continue
        }

        // Line comments
        if let marker = grammar.lineComment,
           marker.count <= scalars.count - i,
           String(scalars[i..<(i + marker.count)]) == marker {
            flushPlain()
            let start = i
            while i < scalars.count, scalars[i] != "\n" { i += 1 }
            tokens.append(Token(text: String(scalars[start..<i]), kind: .comment))
            continue
        }

        // Block comments
        if let (open, close) = grammar.blockComment,
           open.count <= scalars.count - i,
           String(scalars[i..<(i + open.count)]) == open {
            flushPlain()
            let start = i
            i += open.count
            while i + close.count <= scalars.count,
                  String(scalars[i..<(i + close.count)]) != close {
                i += 1
            }
            i = min(scalars.count, i + close.count)
            tokens.append(Token(text: String(scalars[start..<i]), kind: .comment))
            continue
        }

        // Single-line strings
        let ch = scalars[i]
        if grammar.stringDelimiters.contains(ch) {
            flushPlain()
            let delim = ch
            let start = i
            i += 1
            while i < scalars.count, scalars[i] != delim, scalars[i] != "\n" {
                // Skip escaped delimiter
                if scalars[i] == "\\", i + 1 < scalars.count {
                    i += 2
                } else {
                    i += 1
                }
            }
            if i < scalars.count { i += 1 }
            tokens.append(Token(text: String(scalars[start..<i]), kind: .string))
            continue
        }

        // Numbers (integer or decimal). Don't match if previous char is letter
        // — avoids highlighting `a1` as keyword+number.
        if ch.isNumber, i == 0 || !scalars[i - 1].isLetter {
            flushPlain()
            let start = i
            while i < scalars.count, scalars[i].isNumber || scalars[i] == "." || scalars[i] == "_" {
                i += 1
            }
            tokens.append(Token(text: String(scalars[start..<i]), kind: .number))
            continue
        }

        // Identifiers — keyword/type/plain
        if ch.isLetter || ch == "_" {
            let start = i
            while i < scalars.count, scalars[i].isLetter || scalars[i].isNumber || scalars[i] == "_" {
                i += 1
            }
            let word = String(scalars[start..<i])
            if grammar.keywords.contains(word) {
                flushPlain()
                tokens.append(Token(text: word, kind: .keyword))
            } else if grammar.typeByCapitalization,
                      let first = word.first, first.isUppercase {
                flushPlain()
                tokens.append(Token(text: word, kind: .type))
            } else {
                plainBuf += word
            }
            continue
        }

        // Punctuation / whitespace / unknown — kept as plain.
        plainBuf.append(ch)
        i += 1
    }
    flushPlain()
    return tokens
}
