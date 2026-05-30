//
//  ViewModels.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarkdownPDFKit
import Combine

class HomeViewModel: ObservableObject {
    @Published var markdownContent: String = ""
}

class EditorViewModel: ObservableObject {
    /// Shared instance so every file-open path (Finder "Open With", Select
    /// File, drag-drop) funnels into the same editor, mirroring
    /// `AppRouter.shared`.
    static let shared = EditorViewModel()

    @Published var markdownContent: String = ""

    /// Live connection to the source file, when the current document was
    /// opened from one. Nil for "Create New".
    private var session: MarkdownFileSession?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Editor -> file: debounce keystrokes, then write back. The session's
        // own `lastSyncedContent` guard makes a write that equals disk a
        // no-op, so reloads from disk don't echo back out.
        $markdownContent
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] content in
                guard let self, let session = self.session else { return }
                session.write(content)
            }
            .store(in: &cancellables)
    }

    /// Begin a live two-way sync session with the file at `url`.
    func open(url: URL) {
        closeSession()
        let session = MarkdownFileSession(url: url)
        session.onExternalChange = { [weak self] newContent in
            // External file wins: reload into the editor.
            self?.markdownContent = newContent
        }
        session.onDeleted = { [weak self] in
            // Stop writing to a vanished path, but keep the user's text.
            self?.closeSession()
        }
        let loaded = session.start() ?? ""
        self.session = session
        markdownContent = loaded
    }

    /// Tear down the current session (release the security scope, unregister
    /// the file presenter). Safe to call when there is no session.
    func closeSession() {
        session?.stop()
        session = nil
    }

    @MainActor
    func saveAsPDF() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Rendered Markdown as PDF"
        savePanel.nameFieldStringValue = "Markdown.pdf"
        savePanel.allowedContentTypes = [.pdf]

        if savePanel.runModal() == .OK, let saveURL = savePanel.url {
            Task { await generatePDF(to: saveURL) }
        }
    }

    /// Render the current markdown to a PDF using the shared MarkdownPDFKit
    /// engine — the same code path the `md2pdf-cli` tool uses, so the app
    /// and CLI stay byte-for-byte consistent.
    @MainActor
    func generatePDF(to url: URL) async {
        await MarkdownPDFRenderer.render(markdown: markdownContent, to: url)
    }
}
