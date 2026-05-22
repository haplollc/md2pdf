//
//  FileWatcher.swift
//  md2pdf
//
//  Thin wrapper around `DispatchSourceFileSystemObject` that fires a
//  callback when the watched file changes on disk. Used by the editor
//  to pick up external edits (someone modifying the same .md file in
//  Vim, Obsidian, etc.) while keeping the in-app text view in sync.
//
//  Critical detail: `O_EVTONLY` watches a *file descriptor*, which is
//  bound to an inode. Most editors (vim, Obsidian, BBEdit, even
//  TextEdit's autosave) write atomically — they write a temp file and
//  `rename()` it over the target. The original inode is now orphaned,
//  the new file at the same path has a different inode, and our fd
//  keeps watching the dead one. After one atomic save the watcher
//  goes silent forever unless we re-establish it.
//
//  Fix: when the watcher reports `.delete` / `.rename` / `.revoke`,
//  fire the callback one last time (the content really did change),
//  then close the old fd and open a fresh one at the same path. A
//  tiny delay gives the rename time to settle so the new file is
//  guaranteed to be present.
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

        // Watch the broadest useful event set so atomic-save / replace
        // patterns trigger us instead of silently dropping the
        // subscription.
        let mask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .revoke]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: mask,
            queue: .main
        )

        let onChange = self.onChange
        src.setEventHandler { [weak self, weak src] in
            guard let src else { return }
            let events = src.data
            onChange()
            // If the inode this fd points to is gone (deleted / replaced
            // via rename), we'll never get another event on it. Tear it
            // down and re-arm against the path so we keep tracking
            // subsequent atomic saves.
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self?.rearm()
            }
        }
        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        src.resume()
        self.source = src
    }

    /// Tear down the current watcher and re-open the file at the same
    /// path. Used after `.delete` / `.rename` events so atomic-save
    /// editors don't kill the subscription forever.
    private func rearm() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        // Brief delay — `rename()` is atomic at the syscall level but
        // some editors do `unlink → write` which leaves a tiny window
        // where the path doesn't exist. 80ms is comfortably past that
        // for any sane editor and still imperceptible to the user.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            // Verify the file is actually back before we try to open.
            // If it's not (real delete, not a rename), keep retrying
            // for ~2s, then give up. The next user-initiated open will
            // reset everything.
            self.retryOpen(remainingAttempts: 25)
        }
    }

    private func retryOpen(remainingAttempts: Int) {
        if FileManager.default.fileExists(atPath: url.path) {
            start()
            return
        }
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.retryOpen(remainingAttempts: remainingAttempts - 1)
        }
    }

    /// Stop watching. Safe to call multiple times. Called automatically
    /// when the FileWatcher is deallocated.
    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
