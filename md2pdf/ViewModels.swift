//
//  ViewModels.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import UniformTypeIdentifiers
import MarkdownPDFKit
import Combine

class HomeViewModel: ObservableObject {
    @Published var markdownContent: String = ""
}

/// A rendered PDF wrapped for SwiftUI's `.fileExporter`. Carrying the bytes
/// in memory keeps the export cross-platform (the system presents
/// `NSSavePanel` on macOS and the document browser on iOS).
struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

class EditorViewModel: ObservableObject {
    /// Shared instance so every file-open path (Finder "Open With", Select
    /// File, drag-drop) funnels into the same editor, mirroring
    /// `AppRouter.shared`.
    static let shared = EditorViewModel()

    @Published var markdownContent: String = ""

    /// Drives the `.fileExporter` in `EditorView`. `exportDocument` is set
    /// (with freshly rendered PDF bytes) just before `isExportingPDF` flips
    /// true so the exporter always has a document to present.
    @Published var isExportingPDF: Bool = false
    @Published var exportDocument: PDFExportDocument?
    /// True while a PDF is being rendered, so the UI can show progress and
    /// ignore repeat taps.
    @Published var isPreparingPDF: Bool = false

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

    /// Manually re-read the source file. Pulls in any on-disk changes; a
    /// no-op when there is no session or the file matches the editor.
    func reloadFromDisk() {
        guard let newContent = session?.reloadFromDisk() else { return }
        markdownContent = newContent
    }

    /// Tear down the current session (release the security scope, unregister
    /// the file presenter). Safe to call when there is no session.
    func closeSession() {
        session?.stop()
        session = nil
    }

    /// Suggested export filename (without extension) — the source file's
    /// base name (e.g. "filethingy1.md" -> "filethingy1"), or a generic
    /// fallback for "Create New". `.fileExporter` adds the `.pdf` extension.
    var suggestedPDFName: String {
        session?.url.deletingPathExtension().lastPathComponent ?? "Markdown"
    }

    /// Render the current markdown to a PDF and present the system export
    /// UI (save panel on macOS, document browser / share on iOS) via
    /// `.fileExporter`, driven by `isExportingPDF`.
    @MainActor
    func saveAsPDF() {
        guard !isPreparingPDF else { return }
        isPreparingPDF = true
        Task {
            let data = await renderPDFData()
            isPreparingPDF = false
            guard let data else { return }
            exportDocument = PDFExportDocument(data: data)
            isExportingPDF = true
        }
    }

    /// Render the current markdown to PDF bytes using the shared
    /// MarkdownPDFKit engine — the same code path the `md2pdf-cli` tool
    /// uses, so the app and CLI stay byte-for-byte consistent. Renders to a
    /// temp file (the engine writes a `CGPDFContext` to a URL) and reads it
    /// back into memory for the exporter.
    @MainActor
    private func renderPDFData() async -> Data? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        await MarkdownPDFRenderer.render(markdown: markdownContent, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try? Data(contentsOf: tmp)
    }
}
