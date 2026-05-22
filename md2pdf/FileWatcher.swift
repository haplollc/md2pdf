//
//  FileWatcher.swift
//  md2pdf
//
//  Thin wrapper around `DispatchSourceFileSystemObject` that fires a
//  callback when the watched file changes on disk. Used by the editor
//  to pick up external edits (someone modifying the same .md file in
//  Vim, Obsidian, etc.) while keeping the in-app text view in sync.
//

import Foundation

@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        // Can't `await` in deinit; cancel the dispatch source synchronously
        // and let its own cancel handler close the file descriptor.
        source?.cancel()
    }

    private func start() {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        // Watch the broadest useful event set. We can't easily distinguish
        // "the file's path was reused" from "the file moved", so the
        // editor side reads the path again every time it's notified.
        let mask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .revoke]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: mask,
            queue: .main
        )

        let onChange = self.onChange
        src.setEventHandler { onChange() }
        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        src.resume()
        self.source = src
    }

    /// Stop watching. Safe to call multiple times. Called automatically
    /// when the FileWatcher is deallocated.
    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
