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

class HomeViewModel: ObservableObject {
    @Published var markdownContent: String = ""
}

class EditorViewModel: ObservableObject {
    @Published var markdownContent: String = ""

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
