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
        }
        .windowStyle(.hiddenTitleBar)
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
