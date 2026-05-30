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
    @ObservedObject var editorVM = EditorViewModel.shared

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
                                EditorView(viewModel: editorVM)
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

    /// Load a markdown file the user opened from Finder and push the editor.
    /// `open(url:)` starts a live two-way sync session that owns the
    /// security scope for the document's lifetime (released in
    /// `EditorView.onDisappear`).
    private func handleOpenedFile(at url: URL) {
        editorVM.open(url: url)
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
