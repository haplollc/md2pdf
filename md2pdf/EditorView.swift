//
//  EditorView.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import MarkdownUI
import Combine

struct EditorView: View, ModuleRouter {
    enum FocusField: Hashable {
        case field
    }

    var appRouter: AppRouter { AppRouter.shared }

    @ObservedObject var viewModel: EditorViewModel
    @FocusState private var focusedField: FocusField?
    @State private var debouncedContent: String = ""
    @State private var splitFraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat? = nil

    /// Markdown actually displayed in the preview pane — the source after
    /// preprocessing AND after mermaid/remote-image substitution. Empty
    /// until the first async refresh completes.
    @State private var renderedPreview: String = ""
    /// Resolved images (mermaid SVG snapshots + downloaded remotes) keyed
    /// by the custom URL we emit in the substituted markdown.
    @State private var previewImages: [URL: NSImage] = [:]
    /// Cache mermaid diagrams across previews so re-rendering the same
    /// diagram source (very common while editing surrounding text) doesn't
    /// pay the WKWebView boot cost every keystroke.
    @State private var mermaidCache: [String: NSImage] = [:]

    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8
    private let handleWidth: CGFloat = 8

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
            }
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let leftWidth = max(0, totalWidth * splitFraction - handleWidth / 2)
                let rightWidth = max(0, totalWidth * (1 - splitFraction) - handleWidth / 2)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
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
                                    focusedField = .field
                                    debouncedContent = viewModel.markdownContent
                                }
                                .onReceive(viewModel.$markdownContent.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { newValue in
                                    debouncedContent = newValue
                                }
                        }
                        .padding(.horizontal)
                    }
                    .frame(width: leftWidth)

                    SplitterHandle()
                        .frame(width: handleWidth)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = dragStartFraction ?? splitFraction
                                    if dragStartFraction == nil {
                                        dragStartFraction = start
                                    }
                                    guard totalWidth > 0 else { return }
                                    let delta = value.translation.width / totalWidth
                                    splitFraction = min(max(start + delta, minFraction), maxFraction)
                                }
                                .onEnded { _ in
                                    dragStartFraction = nil
                                }
                        )
                        .onHover { hovering in
                            #if os(macOS)
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                            #endif
                        }

                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThickMaterial)

                        ScrollView {
                            Markdown(renderedPreview)
                                .markdownTheme(.docC)
                                .markdownImageProvider(PreloadedImageProvider(cache: previewImages))
                                .markdownCodeSyntaxHighlighter(SyntaxHighlighter())
                                .padding()
                        }
                    }
                    .padding(.horizontal)
                    .frame(width: rightWidth)
                    .task(id: debouncedContent) {
                        await refreshPreview()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save  →") {
                    viewModel.saveAsPDF()
                }
                .buttonStyle(CapsuleButtonStyle(backgroundColor: .accentColor))
                .padding()
                .disableFocusedEffect()
            }
        }
        .navigationBarBackButtonHidden(true)
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
        var images: [URL: NSImage] = [:]
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
        let remote = await EditorViewModel.preloadRemoteImages(in: output)
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

private struct SplitterHandle: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.secondary.opacity(isHovering ? 0.5 : 0.25))
                .frame(width: 4, height: 40)
        }
        .onHover { isHovering = $0 }
    }
}

struct DisableFocusedEffect: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusEffectDisabled()
        } else {
            content
        }
    }
}

extension View {
    func disableFocusedEffect() -> some View {
        self.modifier(DisableFocusedEffect())
    }
}
