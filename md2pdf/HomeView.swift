//
//  HomeView.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct HomeView: View, ModuleRouter {
    // Required by ModuleRouter
    var appRouter: AppRouter { AppRouter.shared }

    // Our local view model
    @ObservedObject var viewModel: HomeViewModel

    // Tracks if the drop area is highlighted
    @State private var isDropTargeted: Bool = false

    var body: some View {
        ZStack {
            // Background drop target using the DropDelegate implementation
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .ignoresSafeArea()
                .onDrop(of: [UTType.fileURL.identifier], delegate: self)

            VStack {
                Image("md2pdf")
                    .resizable()
                    .frame(width: 120, height: 120)

                Text("Markdown to PDF")
                    .font(.title)
                    .bold()
                    .padding(8)

                Text("Easily convert your markdown to a PDF! Drag & drop a .md file here, \nselect a file, or create new to get started!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 20) {
                    Button {
                        selectFile()
                    } label: {
                        Text("Select File")
                    }
                    .buttonStyle(CapsuleButtonStyle(backgroundColor: .gray))
                    .disableFocusedEffect()
                    .padding(.vertical)

                    Button {
                        appRouter.navigate(to: .editor)
                    } label: {
                        Text("Create New")
                    }
                    .buttonStyle(CapsuleButtonStyle(backgroundColor: .accentColor))
                    .disableFocusedEffect()
                    .padding(.vertical)
                }
                .padding()
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - File Selection

    /// Presents an NSOpenPanel to allow the user to choose a Markdown file.
    private func selectFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseFiles = true
        openPanel.allowedFileTypes = ["md"]

        if openPanel.runModal() == .OK, let url = openPanel.url {
            onFileUploaded(url: url)
        }
    }

    /// Start a live two-way sync session for the chosen file and navigate to
    /// the editor. `open(url:)` reads the file and owns its security scope
    /// for the document's lifetime.
    private func onFileUploaded(url: URL) {
        DispatchQueue.main.async {
            EditorViewModel.shared.open(url: url)
            appRouter.navigate(to: .editor)
        }
    }
}

extension HomeView: DropDelegate {
    // Validate that the dropped item conforms to file URL type
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    // Set the drop target state to true when the drop enters the area
    func dropEntered(info: DropInfo) {
        isDropTargeted = true
    }

    // Set the drop target state to false when the drop exits the area
    func dropExited(info: DropInfo) {
        isDropTargeted = false
    }

    // Process the dropped file
    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [UTType.fileURL.identifier]).first else { return false }
        itemProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
            if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    self.onFileUploaded(url: url)
                    self.isDropTargeted = false
                }
            }
        }
        return true
    }
}

