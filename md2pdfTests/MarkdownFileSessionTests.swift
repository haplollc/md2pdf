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

    @Test func writePersistsToDisk() throws {
        let url = try makeTempFile("original\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()

        session.write("changed in app\n")
        #expect(try readFile(url) == "changed in app\n")
    }

    @Test func writeSkippedWhenContentMatchesLastSynced() throws {
        let url = try makeTempFile("hello\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()   // lastSyncedContent == "hello\n"

        // Something else changes the file on disk...
        try "world\n".data(using: .utf8)!.write(to: url)
        // ...and the app's debounced writer fires with the stale, unchanged
        // editor content. It must NOT clobber the newer on-disk content.
        session.write("hello\n")

        #expect(try readFile(url) == "world\n")
    }

    @Test func reloadReturnsNewContentAfterExternalChange() throws {
        let url = try makeTempFile("v1\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()

        try "v2\n".data(using: .utf8)!.write(to: url)
        #expect(session.reloadFromDisk() == "v2\n")
    }

    @Test func reloadReturnsNilWhenContentUnchanged() throws {
        let url = try makeTempFile("same\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()   // lastSyncedContent == "same\n"

        // No external change since start -> nothing to reload.
        #expect(session.reloadFromDisk() == nil)
    }
}
