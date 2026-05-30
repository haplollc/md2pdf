# Two-Way File Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user opens a `.md` file in md2pdf, edits in the app write back to the file, and external changes to the file reload into the editor.

**Architecture:** A new `MarkdownFileSession` (an `NSFilePresenter`) owns the live connection to one file — holding the security scope, doing coordinated reads/writes, and observing external changes. `EditorViewModel` becomes a shared singleton that creates a session on open, debounce-writes edits back, and reloads on external change. Three small wiring edits route every file-open path (Finder "Open With", Select File, drag-drop) through it, and the editor tears the session down on disappear.

**Tech Stack:** Swift, SwiftUI, AppKit, Combine, `NSFileCoordinator`/`NSFilePresenter`, Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-05-30-two-way-file-sync-design.md`

---

## File Structure

- **Create** `md2pdf/MarkdownFileSession.swift` — owns one file's live two-way connection (URL, security scope, coordinated read/write, external-change observation).
- **Create** `md2pdfTests/MarkdownFileSessionTests.swift` — unit tests for the session's deterministic logic.
- **Modify** `md2pdf/ViewModels.swift` — `EditorViewModel` becomes a singleton; gains `session`, `open(url:)`, `closeSession()`, and a debounced writer.
- **Modify** `md2pdf/md2pdfApp.swift` — `handleOpenedFile` funnels into `open(url:)`; use the shared VM; drop the dead `onAppear` content copy.
- **Modify** `md2pdf/HomeView.swift` — Select File / drag-drop funnel into `EditorViewModel.shared.open(url:)`.
- **Modify** `md2pdf/EditorView.swift` — `.onDisappear` closes the session.

### Build & test commands (used throughout)

- Build: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
- Run the session tests: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`

> Note: `xcodebuild` resolves the local Swift packages first, so the first build in a session is slow. Expect `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` on the final line.

---

## Task 1: `MarkdownFileSession` — load existing file on start

**Files:**
- Create: `md2pdf/MarkdownFileSession.swift`
- Test: `md2pdfTests/MarkdownFileSessionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `md2pdfTests/MarkdownFileSessionTests.swift`:

```swift
import Testing
import Foundation
@testable import md2pdf

@Suite(.serialized)
struct MarkdownFileSessionTests {

    /// Writes `content` to a fresh temp `.md` file and returns its URL.
    private func makeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2pdf-session-\(UUID().uuidString).md")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func readFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func startLoadsExistingContent() throws {
        let url = try makeTempFile("# Hello\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }

        let loaded = session.start()
        #expect(loaded == "# Hello\n")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: FAIL — compile error, `cannot find 'MarkdownFileSession' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `md2pdf/MarkdownFileSession.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add md2pdf/MarkdownFileSession.swift md2pdfTests/MarkdownFileSessionTests.swift
git commit -m "Add MarkdownFileSession with coordinated initial load"
```

> The new files must be added to the `md2pdf` and `md2pdfTests` targets. The project uses a file-system-synchronized group, so files dropped under `md2pdf/` and `md2pdfTests/` are picked up automatically — if a target-membership error appears, open the project in Xcode and confirm membership.

---

## Task 2: `MarkdownFileSession.write` — persist edits, skip redundant writes

**Files:**
- Modify: `md2pdf/MarkdownFileSession.swift`
- Test: `md2pdfTests/MarkdownFileSessionTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these two tests inside the `MarkdownFileSessionTests` suite:

```swift
    @Test func writePersistsToDisk() throws {
        let url = try makeTempFile("original\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()

        session.write("changed in app\n")
        #expect(try readFile(url) == "changed in app\n")
    }

    @Test func writeSkippedWhenContentMatchesLastSynced() throws {
        let url = try makeTempFile("hello\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()   // lastSyncedContent == "hello\n"

        // Something else changes the file on disk...
        try "world\n".data(using: .utf8)!.write(to: url)
        // ...and the app's debounced writer fires with the stale, unchanged
        // editor content. It must NOT clobber the newer on-disk content.
        session.write("hello\n")

        #expect(try readFile(url) == "world\n")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: FAIL — compile error, `value of type 'MarkdownFileSession' has no member 'write'`.

- [ ] **Step 3: Write minimal implementation**

Add to `md2pdf/MarkdownFileSession.swift`, after `stop()`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add md2pdf/MarkdownFileSession.swift md2pdfTests/MarkdownFileSessionTests.swift
git commit -m "Add coordinated write-back with self-echo guard"
```

---

## Task 3: `MarkdownFileSession.reloadFromDisk` — detect external changes

**Files:**
- Modify: `md2pdf/MarkdownFileSession.swift`
- Test: `md2pdfTests/MarkdownFileSessionTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these two tests inside the `MarkdownFileSessionTests` suite:

```swift
    @Test func reloadReturnsNewContentAfterExternalChange() throws {
        let url = try makeTempFile("v1\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()

        try "v2\n".data(using: .utf8)!.write(to: url)
        #expect(session.reloadFromDisk() == "v2\n")
    }

    @Test func reloadReturnsNilWhenContentUnchanged() throws {
        let url = try makeTempFile("same\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MarkdownFileSession(url: url)
        defer { session.stop() }
        _ = session.start()   // lastSyncedContent == "same\n"

        // No external change since start -> nothing to reload.
        #expect(session.reloadFromDisk() == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: FAIL — compile error, `value of type 'MarkdownFileSession' has no member 'reloadFromDisk'`.

- [ ] **Step 3: Write minimal implementation**

Add to `md2pdf/MarkdownFileSession.swift`, after `write(_:)`:

```swift
    /// Re-read the file. Returns the new content if it differs from what we
    /// last synced (and records it), else nil.
    func reloadFromDisk() -> String? {
        guard let content = coordinatedRead(), content != lastSyncedContent else {
            return nil
        }
        lastSyncedContent = content
        return content
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add md2pdf/MarkdownFileSession.swift md2pdfTests/MarkdownFileSessionTests.swift
git commit -m "Add reloadFromDisk external-change detection"
```

---

## Task 4: `MarkdownFileSession` — presenter callbacks for change / move / delete

**Files:**
- Modify: `md2pdf/MarkdownFileSession.swift`

This task wires the `NSFilePresenter` callbacks to the public closures. The
callbacks are delivered by the OS on the operation queue and depend on the
file-coordination subsystem, so they are verified manually in Task 9 rather
than unit-tested.

- [ ] **Step 1: Add the callbacks**

Add to `md2pdf/MarkdownFileSession.swift`, in the `// MARK: NSFilePresenter`
section (after `coordinatedRead()` is fine):

```swift
    func presentedItemDidChange() {
        guard let newContent = reloadFromDisk() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onExternalChange?(newContent)
        }
    }

    func presentedItemDidMove(to newURL: URL) {
        // Follow renames/moves so subsequent writes go to the right place.
        url = newURL
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.onDeleted?()
        }
        stop()
        completionHandler(nil)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the session tests (no regressions)**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS' -only-testing:md2pdfTests/MarkdownFileSessionTests`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add md2pdf/MarkdownFileSession.swift
git commit -m "Wire NSFilePresenter change/move/delete callbacks"
```

---

## Task 5: `EditorViewModel` — singleton, sessions, and debounced write-back

**Files:**
- Modify: `md2pdf/ViewModels.swift`

- [ ] **Step 1: Replace `EditorViewModel`**

In `md2pdf/ViewModels.swift`, replace the entire `EditorViewModel` class
(currently lines 17-39) with this. `import Combine` must be present at the top
of the file (add it if missing — the existing imports are `SwiftUI`,
`AppKit`, `UniformTypeIdentifiers`, `MarkdownPDFKit`):

```swift
class EditorViewModel: ObservableObject {
    /// Shared instance so every file-open path (Finder "Open With", Select
    /// File, drag-drop) funnels into the same editor, mirroring
    /// `AppRouter.shared`.
    static let shared = EditorViewModel()

    @Published var markdownContent: String = ""

    /// Live connection to the source file, when the current document was
    /// opened from one. Nil for "Create New".
    private var session: MarkdownFileSession?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Editor -> file: debounce keystrokes, then write back. The session's
        // own `lastSyncedContent` guard makes a write that equals disk a
        // no-op, so reloads from disk don't echo back out.
        $markdownContent
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] content in
                guard let self, let session = self.session else { return }
                session.write(content)
            }
            .store(in: &cancellables)
    }

    /// Begin a live two-way sync session with the file at `url`.
    func open(url: URL) {
        closeSession()
        let session = MarkdownFileSession(url: url)
        session.onExternalChange = { [weak self] newContent in
            // External file wins: reload into the editor.
            self?.markdownContent = newContent
        }
        session.onDeleted = { [weak self] in
            // Stop writing to a vanished path, but keep the user's text.
            self?.closeSession()
        }
        let loaded = session.start() ?? ""
        self.session = session
        markdownContent = loaded
    }

    /// Tear down the current session (release the security scope, unregister
    /// the file presenter). Safe to call when there is no session.
    func closeSession() {
        session?.stop()
        session = nil
    }

    @MainActor
    func saveAsPDF() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Rendered Markdown as PDF"
        savePanel.nameFieldStringValue = "Markdown.pdf"
        savePanel.allowedContentTypes = [.pdf]

        if savePanel.runModal() == .OK, let saveURL = savePanel.url {
            Task { await generatePDF(to: saveURL) }
        }
    }

    /// Render the current markdown to a PDF using the shared MarkdownPDFKit
    /// engine — the same code path the `md2pdf-cli` tool uses, so the app
    /// and CLI stay byte-for-byte consistent.
    @MainActor
    func generatePDF(to url: URL) async {
        await MarkdownPDFRenderer.render(markdown: markdownContent, to: url)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

> If the build fails because the scene still constructs `EditorViewModel()`
> as a `@StateObject`, that is fixed in Task 6 — but build will still pass
> here because `EditorViewModel()` remains a valid initializer.

- [ ] **Step 3: Commit**

```bash
git add md2pdf/ViewModels.swift
git commit -m "Give EditorViewModel file sessions and debounced write-back"
```

---

## Task 6: `md2pdfApp` — funnel opened files through `open(url:)`

**Files:**
- Modify: `md2pdf/md2pdfApp.swift`

- [ ] **Step 1: Use the shared editor view model**

In `md2pdf/md2pdfApp.swift`, change the editor view model from an owned
`@StateObject` to the shared instance (mirrors `@ObservedObject var router =
AppRouter.shared`). Replace:

```swift
    @StateObject var editorVM = EditorViewModel()
```

with:

```swift
    @ObservedObject var editorVM = EditorViewModel.shared
```

- [ ] **Step 2: Remove the dead content-copy on editor appear**

In the `.navigationDestination` `case .editor:` block, the `onAppear` copy is
now obsolete (Home funnels file opens straight into the shared VM in Task 7).
Replace:

```swift
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
```

with:

```swift
                            case .editor:
                                EditorView(viewModel: editorVM)
```

- [ ] **Step 3: Funnel opened files into a sync session**

Replace the entire `handleOpenedFile(at:)` method:

```swift
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
```

with:

```swift
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
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add md2pdf/md2pdfApp.swift
git commit -m "Route Finder-opened files through live sync session"
```

---

## Task 7: `HomeView` — funnel Select File / drag-drop through `open(url:)`

**Files:**
- Modify: `md2pdf/HomeView.swift`

- [ ] **Step 1: Route file opens into the shared editor session**

In `md2pdf/HomeView.swift`, replace `onFileUploaded(url:)` (currently lines
85-95):

```swift
    /// Loads file content from the provided URL and navigates to the editor.
    private func onFileUploaded(url: URL) {
        if let content = try? String(contentsOf: url) {
            DispatchQueue.main.async {
                viewModel.markdownContent = content
                appRouter.navigate(to: .editor)
            }
        } else {
            print("Failed to load file content from \(url)")
        }
    }
```

with:

```swift
    /// Start a live two-way sync session for the chosen file and navigate to
    /// the editor. `open(url:)` reads the file and owns its security scope
    /// for the document's lifetime.
    private func onFileUploaded(url: URL) {
        DispatchQueue.main.async {
            EditorViewModel.shared.open(url: url)
            appRouter.navigate(to: .editor)
        }
    }
```

> `viewModel` (the `HomeViewModel`) is no longer touched here; that is
> expected — the editor now owns the document.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add md2pdf/HomeView.swift
git commit -m "Route Select File and drag-drop through live sync session"
```

---

## Task 8: `EditorView` — close the session on disappear

**Files:**
- Modify: `md2pdf/EditorView.swift`

- [ ] **Step 1: Tear down the session when leaving the editor**

In `md2pdf/EditorView.swift`, find the closing modifiers of the top-level
`VStack` body (currently line 168):

```swift
        .navigationBarBackButtonHidden(true)
```

Replace with:

```swift
        .navigationBarBackButtonHidden(true)
        .onDisappear {
            // Leaving the editor ends the document's lifetime: release the
            // security scope and stop observing the file.
            viewModel.closeSession()
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite (no regressions)**

Run: `xcodebuild test -scheme md2pdf -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add md2pdf/EditorView.swift
git commit -m "Close file session when leaving the editor"
```

---

## Task 9: Manual end-to-end verification

**Files:** none (manual QA of the file-coordination paths that can't be unit-tested).

- [ ] **Step 1: Build and launch the app**

Run: `xcodebuild build -scheme md2pdf -destination 'platform=macOS'` then launch the built app (or run from Xcode with ⌘R). Create a test file first:

```bash
printf '# Sync test\n\nhello\n' > /tmp/synctest.md
```

- [ ] **Step 2: Verify editor -> file (auto-save)**

Open `/tmp/synctest.md` via Finder "Open With → md2pdf" (or Select File). In
the editor, type a new line. Wait ~1 second, then in a terminal:

Run: `cat /tmp/synctest.md`
Expected: the file contains your typed change.

- [ ] **Step 3: Verify file -> editor (external change reloads)**

With the document still open in md2pdf, edit the file externally:

Run: `printf '# Sync test\n\nedited externally\n' > /tmp/synctest.md`
Expected: within a moment, the md2pdf editor pane updates to show
"edited externally".

- [ ] **Step 4: Verify atomic save-by-rename is observed**

Open `/tmp/synctest.md` in a text editor that saves atomically (e.g. `vim`,
VS Code, or BBEdit), change the text, and save.
Expected: md2pdf reflects the change (this is the case a raw fd watcher would
miss after the first save).

- [ ] **Step 5: Verify Select File and drag-drop paths sync too**

From Home, use "Select File" to open a `.md`, type a change, wait ~1s,
`cat` the file → change is present. Repeat by dragging a `.md` onto Home.
Expected: both paths write back.

- [ ] **Step 6: Verify "Create New" stays unsynced and leaving cleans up**

From Home, "Create New", type some text — no file is written (nothing to sync
to). Open a real file, then tap the back chevron to return Home and confirm
the app remains responsive (session torn down). Re-open the same file and
confirm edits still sync (scope re-acquired cleanly).

- [ ] **Step 7: Clean up**

```bash
rm -f /tmp/synctest.md
```

---

## Self-Review Notes

- **Spec coverage:** session unit (Tasks 1-4) ✓; VM singleton + open/close + debounced write (Task 5) ✓; `md2pdfApp` wiring (Task 6) ✓; `HomeView` wiring (Task 7) ✓; `EditorView` teardown (Task 8) ✓; external delete keeps text (Task 5 `onDeleted` → `closeSession`, no content reset) ✓; rename follows file (Task 4 `presentedItemDidMove`) ✓; self-echo guard (`lastSyncedContent`, Tasks 2-3) ✓; UTF-8 throughout ✓; auto-save debounce ✓; external-wins reload ✓; all open paths ✓.
- **Method/type names** are consistent across tasks: `open(url:)`, `closeSession()`, `start()`, `stop()`, `write(_:)`, `reloadFromDisk()`, `onExternalChange`, `onDeleted`, `lastSyncedContent`.
- **Out of scope (per spec):** security-scoped bookmarks across launches, saving "Create New" to a `.md`, merge UI.
