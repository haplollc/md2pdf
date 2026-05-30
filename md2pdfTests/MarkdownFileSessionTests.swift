//
//  MarkdownFileSessionTests.swift
//  md2pdfTests
//

import Testing
import Foundation
@testable import md2pdf

@Suite(.serialized)
struct MarkdownFileSessionTests {

    /// Writes `content` to a fresh temp `.md` file and returns its URL.
    private func makeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2pdf-session-\(UUID().uuidString).md")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func readFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func startLoadsExistingContent() throws {
        let url = try makeTempFile("# Hello\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }

        let loaded = session.start()
        #expect(loaded == "# Hello\n")
    }
}
