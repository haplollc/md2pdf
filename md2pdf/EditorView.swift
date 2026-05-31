//
//  EditorView.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import Markdown
import MarkdownPDFKit
import Combine
import UniformTypeIdentifiers

struct EditorView: View, ModuleRouter {
    enum FocusField: Hashable {
        case field
    }

    var appRouter: AppRouter { AppRouter.shared }

    @ObservedObject var viewModel: EditorViewModel
    @FocusState private var focusedField: FocusField?
    @State private var debouncedContent: String = ""

    /// Editor's left/right split, persisted across launches so opening
    /// a doc again restores the user's preferred ratio.
    @AppStorage("editor.splitFraction") private var splitFractionStorage: Double = 0.5
    @State private var dragStartFraction: Double? = nil
    /// True for the duration of a splitter drag. While dragging, the heavy
    /// preview pane is replaced with a cheap placeholder so resize stays
    /// smooth even on docs full of images + mermaid + tables.
    @State private var isResizing: Bool = false

    /// Markdown actually displayed in the preview pane — the source after
    /// preprocessing AND after mermaid/remote-image substitution. Empty
    /// until the first async refresh completes.
    @State private var renderedPreview: String = ""
    /// Resolved images (mermaid SVG snapshots + downloaded remotes) keyed
    /// by the custom URL we emit in the substituted markdown.
    @State private var previewImages: [URL: PlatformImage] = [:]
    /// Cache mermaid diagrams across previews so re-rendering the same
    /// diagram source (very common while editing surrounding text) doesn't
    /// pay the WKWebView boot cost every keystroke.
    @State private var mermaidCache: [String: PlatformImage] = [:]

    /// Panes can be dragged all the way closed so the user can focus on just
    /// the editor or just the preview; double-tapping the divider re-balances.
    private let minFraction: Double = 0.0
    private let maxFraction: Double = 1.0
    private let handleWidth: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    appRouter.pop()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(.ultraThickMaterial)
                        .clipShape(Circle())
                }
                .disableFocusedEffect()
                .buttonStyle(.borderless)
                .padding([.bottom, .horizontal])

                Spacer()

                Button {
                    viewModel.reloadFromDisk()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(.ultraThickMaterial)
                        .clipShape(Circle())
                }
                .disableFocusedEffect()
                .buttonStyle(.borderless)
                .padding([.bottom, .horizontal])
                .help("Refresh from file")
            }
            GeometryReader { geo in
                // Side-by-side when the viewport is wider than tall (macOS
                // windows, landscape, most iPad); stacked editor-over-preview
                // when taller than wide (iPhone portrait, iPad portrait).
                let isWide = geo.size.width >= geo.size.height
                let total = isWide ? geo.size.width : geo.size.height
                let firstExtent = max(0, total * CGFloat(splitFractionStorage) - handleWidth / 2)
                let secondExtent = max(0, total * CGFloat(1 - splitFractionStorage) - handleWidth / 2)

                if isWide {
                    HStack(spacing: 0) {
                        editorPane.frame(width: firstExtent)
                        splitter(isWide: true, total: total)
                        previewPane.frame(width: secondExtent)
                    }
                } else {
                    VStack(spacing: 0) {
                        editorPane.frame(height: firstExtent)
                        splitter(isWide: false, total: total)
                        previewPane.frame(height: secondExtent)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    viewModel.saveAsPDF()
                } label: {
                    if viewModel.isPreparingPDF {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save  →")
                    }
                }
                .buttonStyle(CapsuleButtonStyle(backgroundColor: .accentColor))
                .disabled(viewModel.isPreparingPDF)
                .padding()
                .disableFocusedEffect()
            }
        }
        .navigationBarBackButtonHidden(true)
        .fileExporter(
            isPresented: $viewModel.isExportingPDF,
            document: viewModel.exportDocument,
            contentType: .pdf,
            defaultFilename: viewModel.suggestedPDFName
        ) { _ in
            // Success or cancellation are both fine; nothing to do here.
        }
        .onDisappear {
            // Leaving the editor ends the document's lifetime: release the
            // security scope and stop observing the file.
            viewModel.closeSession()
        }
    }

    // MARK: - Panes

    private var editorPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThickMaterial)

            TextEditor(text: $viewModel.markdownContent)
                .padding(10)
                .scrollContentBackground(.hidden)
                .backgroundStyle(.clear)
                .font(.body)
                .focused($focusedField, equals: .field)
                .onAppear {
                    debouncedContent = viewModel.markdownContent
                    // Auto-focus on macOS (no keyboard to intrude); on iOS we
                    // let the user tap in so the keyboard doesn't cover the
                    // preview the moment the editor opens.
                    #if os(macOS)
                    focusedField = .field
                    #endif
                }
                .onReceive(viewModel.$markdownContent.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { newValue in
                    debouncedContent = newValue
                }
        }
        .padding(.horizontal)
        .clipped()
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThickMaterial)

            // During a splitter drag we swap the full Markdown render for a
            // lightweight "loading" stand-in so the drag stays smooth —
            // re-flowing the rendered preview (images, mermaid SVGs, tables,
            // syntax-highlighted code) on every drag tick is what was
            // glitching before. The full preview snaps back at drag end.
            if isResizing {
                ResizingPlaceholder()
            } else {
                ScrollView {
                    Markdown(renderedPreview)
                        .markdownTheme(.docC)
                        .markdownImageProvider(PreloadedImageProvider(cache: previewImages))
                        .markdownCodeSyntaxHighlighter(SyntaxHighlighter())
                        .padding()
                }
            }
        }
        .padding(.horizontal)
        .clipped()
        .task(id: debouncedContent) {
            await refreshPreview()
        }
    }

    /// The draggable divider. Orients itself along the split axis: a vertical
    /// bar dragged horizontally when side-by-side, a horizontal bar dragged
    /// vertically when stacked. Drag to collapse either pane; double-tap to
    /// re-balance to 50/50.
    private func splitter(isWide: Bool, total: CGFloat) -> some View {
        SplitterHandle(isWide: isWide)
            .frame(width: isWide ? handleWidth : nil,
                   height: isWide ? nil : handleWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartFraction ?? splitFractionStorage
                        if dragStartFraction == nil {
                            dragStartFraction = start
                            isResizing = true
                        }
                        guard total > 0 else { return }
                        let translation = isWide ? value.translation.width : value.translation.height
                        let delta = Double(translation) / Double(total)
                        splitFractionStorage = min(max(start + delta, minFraction), maxFraction)
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        isResizing = false
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    splitFractionStorage = 0.5
                }
            }
            .onHover { hovering in
                #if os(macOS)
                if hovering {
                    (isWide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
    }

    /// Builds the preview's rendered markdown + image map. Mirrors what
    /// `EditorViewModel.generatePDF` does so what you see is what you save:
    ///   1. preprocess the source (footnotes / math),
    ///   2. render every ```mermaid``` block to an NSImage (cached across
    ///      keystrokes so unchanged diagrams don't re-render),
    ///   3. preload every absolute-URL image so they appear right away
    ///      *and* at their natural size, just like in the exported PDF,
    ///   4. emit a custom-scheme image reference for each rendered asset
    ///      and update the @State so the Markdown view re-renders.
    @MainActor
    private func refreshPreview() async {
        let processed = MarkdownPreprocessor.process(debouncedContent)

        // 1. Mermaid — render only diagrams we haven't seen before, then
        //    pull every needed diagram out of the persistent cache.
        let mermaidCodes = MarkdownPreprocessor.extractMermaid(processed)
        let unseen = mermaidCodes.filter { mermaidCache[$0] == nil }
        if !unseen.isEmpty {
            let fresh = await MermaidRenderer.renderAll(unseen)
            for (code, img) in fresh {
                mermaidCache[code] = img
            }
        }
        var mermaidURLs: [String: URL] = [:]
        var images: [URL: PlatformImage] = [:]
        for code in Set(mermaidCodes) {
            guard let img = mermaidCache[code] else { continue }
            let url = URL(string: "mermaidimg://\(abs(code.hashValue))")!
            mermaidURLs[code] = url
            images[url] = img
        }
        let output = MarkdownPreprocessor.replaceMermaid(in: processed, withImageURLs: mermaidURLs)

        // 2. Remote URL images — preload so they render at natural size
        //    via PreloadedImageProvider instead of MarkdownUI's default
        //    column-stretching NetworkImage path.
        let remote = await MarkdownPDFRenderer.preloadRemoteImages(in: output)
        for (url, img) in remote {
            images[url] = img
        }

        // Only push to @State if the work wasn't cancelled meanwhile —
        // SwiftUI tasks get cancelled when their id changes mid-flight.
        guard !Task.isCancelled else { return }
        renderedPreview = output
        previewImages = images
    }
}

/// Lightweight skeleton shown in the preview pane while the user is
/// dragging the splitter — re-laying out the full Markdown render on
/// every drag tick stutters badly on docs with images / mermaid / tables.
/// Looks "page-like" so the resize still tells the user what they're
/// going to get.
private struct ResizingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 220, height: 22)
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 10)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 80)
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 10)
            }
            Spacer()
        }
        .padding()
    }
}

private struct SplitterHandle: View {
    let isWide: Bool
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.secondary.opacity(isHovering ? 0.55 : 0.3))
                .frame(width: isWide ? 4 : 40, height: isWide ? 40 : 4)
        }
        .onHover { isHovering = $0 }
    }
}

struct DisableFocusedEffect: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
        #else
        if #available(iOS 17.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
        #endif
    }
}

extension View {
    func disableFocusedEffect() -> some View {
        self.modifier(DisableFocusedEffect())
    }
}
