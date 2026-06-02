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

    /// Drives the macOS `.fileExporter` in `EditorView`. `exportDocument` is
    /// set (with freshly rendered PDF bytes) just before `isExportingPDF`
    /// flips true so the exporter always has a document to present.
    @Published var isExportingPDF: Bool = false
    @Published var exportDocument: PDFExportDocument?
    /// Drives the iOS share sheet — set to the rendered PDF's file URL.
    @Published var shareItem: ShareItem?
    /// True while a PDF is being rendered, so the UI can show a spinner and
    /// ignore repeat taps.
    @Published var isPreparingPDF: Bool = false
    /// True briefly after a successful render so the button can show an
    /// animated "Done" checkmark before reverting to "Save".
    @Published var didCompleteSave: Bool = false
    private var doneResetTask: Task<Void, Never>?

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
    /// UI: a share sheet on iOS, the save panel on macOS. A spinner shows
    /// while `isPreparingPDF` is true.
    @MainActor
    func saveAsPDF(named name: String? = nil) {
        guard !isPreparingPDF else { return }
        doneResetTask?.cancel()
        didCompleteSave = false
        isPreparingPDF = true
        Task {
            let url = await renderPDFToTempFile(named: name)
            guard let url else {
                isPreparingPDF = false
                return
            }
            #if os(iOS)
            // The share sheet reads the file directly; leave it in the temp
            // directory (the system reclaims it).
            shareItem = ShareItem(url: url)
            #else
            if let data = try? Data(contentsOf: url) {
                exportDocument = PDFExportDocument(data: data)
                isExportingPDF = true
            }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            #endif
            // Swap the spinner for the animated "Done" checkmark, then revert
            // to "Save" after 3 seconds.
            withAnimation {
                isPreparingPDF = false
                didCompleteSave = true
            }
            doneResetTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { didCompleteSave = false }
            }
        }
    }

    /// Render the current markdown to a temp PDF file using the shared
    /// MarkdownPDFKit engine — the same code path the `md2pdf-cli` tool uses,
    /// so the app and CLI stay byte-for-byte consistent. The file is named
    /// after the document so the share sheet / saved file is sensibly titled.
    /// Returns nil on failure.
    @MainActor
    private func renderPDFToTempFile(named name: String?) async -> URL? {
        // Use the user-supplied name (iOS alert) when present, else the
        // document's name. Strip any path separators / extension the user
        // may have typed.
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = (trimmed.isEmpty ? suggestedPDFName : trimmed)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".pdf", with: "")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(base.isEmpty ? "Markdown" : base).appendingPathExtension("pdf")
        await MarkdownPDFRenderer.render(markdown: markdownContent, to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Identifiable wrapper so a rendered PDF's URL can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
