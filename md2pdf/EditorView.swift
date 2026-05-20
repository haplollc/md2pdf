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
                            Markdown(MarkdownPreprocessor.process(debouncedContent))
                                .markdownTheme(.docC)
                                .padding()
                        }
                    }
                    .padding(.horizontal)
                    .frame(width: rightWidth)
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
