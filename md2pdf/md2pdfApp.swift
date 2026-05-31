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
            .platformWindowMinSize()
            .customContainerBackground()
            // "Open With → md2pdf" from Finder (macOS) or the Files/share
            // sheet (iOS) lands here. Same path for cold launch (the OS
            // grants the security-scoped URL before the first frame) and
            // warm reactivation while the app's already running.
            .onOpenURL { url in
                handleOpenedFile(at: url)
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
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
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content
                .containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content
        }
        #else
        // iOS has no window container background; the system manages it.
        content
        #endif
    }
}

extension View {
    func customContainerBackground() -> some View {
        self.modifier(CustomContainerBackground())
    }

    /// A sensible minimum window size on macOS; a no-op on iOS, where the
    /// app fills the device/scene and a fixed minimum would break the
    /// iPhone layout.
    @ViewBuilder func platformWindowMinSize() -> some View {
        #if os(macOS)
        self.frame(minWidth: 800, minHeight: 600)
        #else
        self
        #endif
    }
}
