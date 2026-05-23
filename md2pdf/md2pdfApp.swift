//
//  md2pdfApp.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI

@main
struct md2pdfApp: App {
    // Singletons / ObservedObjects as needed
    @ObservedObject var router = AppRouter.shared

    // Simple shared VMs; you could do more advanced logic for scoping them
    @StateObject var homeVM = HomeViewModel()
    @StateObject var editorVM = EditorViewModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $router.path) {
                // Start with HomeView
                HomeView(viewModel: homeVM)
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                            case .home:
                                HomeView(viewModel: homeVM)
                            case .editor:
                                // Initialize EditorView, pass the content from home VM
                                // or keep them separate if you prefer
                                EditorView(viewModel: editorVM)
                                    .onAppear {
                                        // If user came directly from Home with dragged content:
                                        // transfer the content
                                        if !homeVM.markdownContent.isEmpty {
                                            editorVM.markdownContent = homeVM.markdownContent
                                            homeVM.markdownContent = ""
                                        }
                                    }
                        }
                    }
            }
            .frame(minWidth: 800, minHeight: 600)
            .customContainerBackground()
            // "Open With → md2pdf" from Finder lands here. Same path for
            // cold launch (Powerbox grants the security-scoped URL before
            // the first frame) and warm reactivation while the app's
            // already running.
            .onOpenURL { url in
                handleOpenedFile(at: url)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }

    /// Load a markdown file the user opened from Finder, push the
    /// editor onto the navigation stack. We deliberately replace any
    /// editor-in-progress content — the explicit "open this file"
    /// gesture is unambiguous about what should be on screen now.
    private func handleOpenedFile(at url: URL) {
        // Some files Finder hands us are security-scoped; balance the
        // start/stop pair so we don't leak the access grant.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        editorVM.markdownContent = content
        // Reset the path so we always land in the editor, even if the
        // user was somewhere else when the open happened.
        router.path = NavigationPath()
        router.navigate(to: .editor)
    }
}

struct CustomContainerBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content
        }
    }
}

extension View {
    func customContainerBackground() -> some View {
        self.modifier(CustomContainerBackground())
    }
}
