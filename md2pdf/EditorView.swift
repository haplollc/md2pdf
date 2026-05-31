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
    var appRouter: AppRouter { AppRouter.shared }

    @ObservedObject var viewModel: EditorViewModel
    @State private var debouncedContent: String = ""

    /// Editor's left/right split, persisted across launches so opening
    /// a doc again restores the user's preferred ratio.
    @AppStorage("editor.splitFraction") private var splitFractionStorage: Double = 0.5
    @State private var dragStartFraction: Double? = nil
    /// True for the duration of a splitter drag. While dragging, the heavy
    /// preview pane is replaced with a cheap placeholder so resize stays
    /// smooth even on docs full of images + mermaid + tables.
    @State private var isResizing: Bool = false

    /// Resolved images (mermaid SVG snapshots + downloaded remotes) keyed
    /// by the custom URL we emit in the substituted markdown.
    @State private var previewImages: [URL: PlatformImage] = [:]
    /// Cache mermaid diagrams across previews so re-rendering the same
    /// diagram source (very common while editing surrounding text) doesn't
    /// pay the WKWebView boot cost every keystroke.
    @State private var mermaidCache: [String: PlatformImage] = [:]

    // MARK: Scroll sync state

    /// Source-line range of each raw-source block, used to map the editor's
    /// top visible line to a block index.
    @State private var sourceBlocks: [SourceBlock] = []
    /// The rendered preview split into the same blocks the editor is split
    /// into, so block index N in the editor lines up with block N here.
    @State private var previewBlocks: [PreviewBlock] = []
    /// Block index the preview should scroll to (driven by editor scrolling).
    @State private var previewScrollTarget: Int?
    /// Command telling the editor to scroll a line to the top (driven by
    /// preview scrolling).
    @State private var editorScrollCommand: ScrollToLine?
    @State private var scrollToken: Int = 0
    /// Which pane is currently driving a sync, so the follower's induced
    /// scroll isn't bounced back as a new drive (feedback loop guard).
    @State private var activeDriver: ScrollDriver?
    @State private var driverResetWork: DispatchWorkItem?

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
                        .glassIconBackground()
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
                        .glassIconBackground()
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
            // Breathing room below the panes (below the preview / markdown
            // view) so the content isn't flush against the Save button.
            .padding(.bottom, 8)

            // macOS keeps the trailing capsule; iOS gets a full-width bar
            // pinned to the bottom safe area (added below via `.apply`).
            #if os(macOS)
            HStack {
                Spacer()
                trailingSaveButton
            }
            #endif
        }
        .apply {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                $0.safeAreaBar(edge: .bottom, alignment: .center, spacing: 0) {
                    bottomActionBar
                }
            } else {
                $0.safeAreaInset(edge: .bottom) {
                    bottomActionBar
                }
            }
            #else
            $0
            #endif
        }
        .navigationBarBackButtonHidden(true)
        #if os(macOS)
        .fileExporter(
            isPresented: $viewModel.isExportingPDF,
            document: viewModel.exportDocument,
            contentType: .pdf,
            defaultFilename: viewModel.suggestedPDFName
        ) { _ in
            // Success or cancellation are both fine; nothing to do here.
        }
        #else
        .sheet(item: $viewModel.shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        #endif
        .onDisappear {
            // Leaving the editor ends the document's lifetime: release the
            // security scope and stop observing the file.
            viewModel.closeSession()
        }
    }

    // MARK: - Save button

    /// Button content: a spinner + "Preparing…" while the PDF renders,
    /// otherwise "Save →". White foreground is supplied by the capsule style.
    @ViewBuilder private var saveButtonLabel: some View {
        if viewModel.isPreparingPDF {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Preparing…")
            }
        } else {
            Text("Save  →")
        }
    }

    /// macOS: trailing capsule, matching the desktop idiom.
    private var trailingSaveButton: some View {
        Button { viewModel.saveAsPDF() } label: { saveButtonLabel }
            .buttonStyle(GlassCapsuleButtonStyle(tint: .accentColor, fallbackBackground: .accentColor))
            .disabled(viewModel.isPreparingPDF)
            .padding()
            .disableFocusedEffect()
    }

    /// iOS: full-width bar pinned to the bottom safe area.
    private var bottomActionBar: some View {
        Button { viewModel.saveAsPDF() } label: {
            saveButtonLabel.frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassCapsuleButtonStyle(tint: .accentColor, fallbackBackground: .accentColor))
        .disabled(viewModel.isPreparingPDF)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Panes

    private var editorPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThickMaterial)

            SyncingTextEditor(
                text: $viewModel.markdownContent,
                onTopLineChanged: { line in handleEditorScrolled(toTopLine: line) },
                scrollToLine: editorScrollCommand
            )
            .padding(6)
            .onAppear {
                debouncedContent = viewModel.markdownContent
                rebuildSourceBlocks()
            }
            .onReceive(viewModel.$markdownContent.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { newValue in
                debouncedContent = newValue
                rebuildSourceBlocks()
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(previewBlocks) { block in
                                Markdown(block.text)
                                    .markdownTheme(.docC)
                                    .markdownImageProvider(PreloadedImageProvider(cache: previewImages))
                                    .markdownCodeSyntaxHighlighter(SyntaxHighlighter())
                                    .id(block.id)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: BlockTopPreferenceKey.self,
                                                value: [block.id: geo.frame(in: .named(Self.previewSpace)).minY]
                                            )
                                        }
                                    )
                            }
                        }
                        .padding()
                    }
                    .coordinateSpace(name: Self.previewSpace)
                    .onPreferenceChange(BlockTopPreferenceKey.self) { tops in
                        handlePreviewScrolled(blockTops: tops)
                    }
                    .onChange(of: previewScrollTarget) { target in
                        guard let target else { return }
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .padding(.horizontal)
        .clipped()
        .task(id: debouncedContent) {
            await refreshPreview()
        }
    }

    private static let previewSpace = "previewScrollSpace"

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
        previewImages = images
        previewBlocks = Self.splitPreviewBlocks(output)
        // Source blocks are split from the raw editor text so block N in the
        // editor maps to block N in the preview.
        rebuildSourceBlocks()
    }

    // MARK: - Scroll sync

    private func rebuildSourceBlocks() {
        sourceBlocks = Self.splitSourceBlocks(viewModel.markdownContent)
    }

    /// User scrolled the editor: scroll the preview to the block holding the
    /// editor's new top line. Ignored when the preview is the active driver,
    /// so the follower's induced scroll isn't bounced back.
    private func handleEditorScrolled(toTopLine line: Int) {
        guard activeDriver != .preview else { return }
        guard let index = sourceBlockIndex(forLine: line) else { return }
        setDriver(.editor)
        let target = min(index, max(0, previewBlocks.count - 1))
        if previewScrollTarget != target { previewScrollTarget = target }
    }

    /// User scrolled the preview: scroll the editor to the start line of the
    /// preview's top visible block. Ignored when the editor is driving.
    private func handlePreviewScrolled(blockTops: [Int: CGFloat]) {
        guard activeDriver != .editor, !blockTops.isEmpty else { return }
        // Top visible block = the one whose top is nearest the viewport top
        // from above (minY <= 0); fall back to the first block at the very top.
        let topBlock = blockTops.filter { $0.value <= 1 }.max(by: { $0.value < $1.value })?.key
            ?? blockTops.min(by: { $0.value < $1.value })?.key
        guard let topBlock, topBlock < sourceBlocks.count else { return }
        setDriver(.preview)
        scrollToken += 1
        editorScrollCommand = ScrollToLine(line: sourceBlocks[topBlock].startLine, token: scrollToken)
    }

    /// The block index containing `line` (or the nearest preceding block when
    /// the line falls in a blank gap).
    private func sourceBlockIndex(forLine line: Int) -> Int? {
        guard !sourceBlocks.isEmpty else { return nil }
        if let exact = sourceBlocks.first(where: { line >= $0.startLine && line < $0.startLine + $0.lineCount }) {
            return exact.id
        }
        return sourceBlocks.last(where: { $0.startLine <= line })?.id ?? 0
    }

    /// Records which pane is actively driving the sync and clears it shortly
    /// after, so the other pane's induced scroll events don't feed back.
    private func setDriver(_ driver: ScrollDriver) {
        activeDriver = driver
        driverResetWork?.cancel()
        let work = DispatchWorkItem { activeDriver = nil }
        driverResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Splits raw markdown into blank-line-separated blocks, tracking each
    /// block's starting (0-based) source line and line count.
    static func splitSourceBlocks(_ text: String) -> [SourceBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [SourceBlock] = []
        var i = 0
        var index = 0
        while i < lines.count {
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            guard i < lines.count else { break }
            let start = i
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            blocks.append(SourceBlock(id: index, startLine: start, lineCount: i - start))
            index += 1
        }
        return blocks
    }

    /// Splits the rendered markdown into the same blank-line blocks, so each
    /// can be laid out separately and positioned for scroll syncing.
    static func splitPreviewBlocks(_ text: String) -> [PreviewBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [PreviewBlock] = []
        var current: [String] = []
        var index = 0
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(PreviewBlock(id: index, text: joined))
                index += 1
            }
            current = []
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// Source-line range of a raw-markdown block.
struct SourceBlock: Identifiable, Equatable {
    let id: Int
    let startLine: Int
    let lineCount: Int
}

/// One blank-line-separated block of the rendered preview.
struct PreviewBlock: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Which pane is currently driving a scroll sync.
private enum ScrollDriver {
    case editor
    case preview
}

/// Collects each preview block's top offset within the scroll view, so the
/// top visible block can be found.
struct BlockTopPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Apply a transform to a view inline. Lets us branch on OS availability
    /// (e.g. `safeAreaBar` on iOS 26+ vs `safeAreaInset` below) within a
    /// modifier chain. The closure is a view builder so `if #available`
    /// branches with different result types unify.
    @ViewBuilder func apply<V: View>(@ViewBuilder _ transform: (Self) -> V) -> some View {
        transform(self)
    }
}

#if os(iOS)
/// Wraps `UIActivityViewController` so the rendered PDF can be shared/saved
/// through the system share sheet (Files, AirDrop, Mail, …).
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

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
