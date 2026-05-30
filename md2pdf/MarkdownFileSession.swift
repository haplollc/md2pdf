//
//  MarkdownFileSession.swift
//  md2pdf
//

import Foundation

/// Owns the live, two-way connection between the editor and one Markdown
/// file on disk. Registers as an `NSFilePresenter` so external edits
/// (including the atomic save-by-rename most editors perform) are observed,
/// and writes the editor's changes back through coordinated writes. A single
/// `lastSyncedContent` guard suppresses our own writes from bouncing back as
/// reloads.
final class MarkdownFileSession: NSObject, NSFilePresenter {
    private(set) var url: URL
    private let isScoped: Bool
    private var lastSyncedContent: String = ""

    /// Called on the main thread with new file content when the file changes
    /// on disk from outside the app (external -> editor).
    var onExternalChange: ((String) -> Void)?
    /// Called on the main thread when the file is deleted on disk.
    var onDeleted: (() -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "MarkdownFileSession"
        return q
    }()

    init(url: URL) {
        self.url = url
        // For Finder "Open With" / panel / drag URLs the grant is
        // security-scoped; hold it for the whole session. Returns false for
        // unscoped URLs, which is harmless.
        self.isScoped = url.startAccessingSecurityScopedResource()
        super.init()
    }

    // MARK: NSFilePresenter

    var presentedItemURL: URL? { url }
    var presentedItemOperationQueue: OperationQueue { queue }

    /// Register as a presenter and return the file's current content.
    func start() -> String? {
        NSFileCoordinator.addFilePresenter(self)
        let content = coordinatedRead()
        if let content { lastSyncedContent = content }
        return content
    }

    /// Unregister and release the security scope. Idempotent.
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if isScoped { url.stopAccessingSecurityScopedResource() }
    }

    /// Write `content` back to disk unless it already matches what we last
    /// synced (suppresses redundant writes and self-echo reloads).
    func write(_ content: String) {
        guard content != lastSyncedContent else { return }
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            guard let data = content.data(using: .utf8) else { return }
            do {
                try data.write(to: writeURL)
                lastSyncedContent = content
            } catch {
                // Leave lastSyncedContent unchanged so a later edit retries.
            }
        }
    }

    private func coordinatedRead() -> String? {
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        var result: String?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = try? String(contentsOf: readURL, encoding: .utf8)
        }
        return result
    }
}
