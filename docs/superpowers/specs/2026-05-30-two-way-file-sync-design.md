# Two-Way File Sync for Opened Markdown Files

**Date:** 2026-05-30
**Status:** Approved design

## Problem

When a user opens a `.md` file in md2pdf — via Finder "Open With", the
in-app "Select File" panel, or drag-and-drop onto Home — the editor and the
file on disk are disconnected:

- Edits made in md2pdf are never written back to the source `.md`. The only
  save path is "Save as PDF".
- The source file URL is discarded immediately after the initial read
  (`md2pdfApp.handleOpenedFile` starts the security scope and releases it via
  `defer` in the same call), so there is nothing to write back to or watch.

The user wants live two-way sync: edits in md2pdf update the `.md` file, and
external changes to the `.md` file update the editor.

## Decisions

- **Save timing:** auto-save, debounced (~0.6s after the last keystroke). No
  manual save button for the `.md`.
- **Conflict policy:** external file wins. If the file changes on disk, the
  editor reloads from disk. (With debounced auto-save the unsaved window is
  small.)
- **Scope:** all file-open paths get live sync — Finder "Open With", "Select
  File", and drag-and-drop. "Create New" stays unsynced (it has no file).
- **Encoding:** UTF-8 for all reads and writes.

## Approach

Keep the existing app architecture (`WindowGroup` + `NavigationStack`, Home →
Editor, markdown passed as a `String`). Add a focused file-sync layer rather
than migrating to `DocumentGroup`/`NSDocument` (which would force a
document-centric rearchitecture of the Home flow, Create New, and drag-drop —
high churn, high risk for a one-screen feature).

Watch the file with **`NSFilePresenter` + `NSFileCoordinator`**, not a raw
file-descriptor watcher (kqueue/`DispatchSource`). Most editors save
atomically by replacing the file (write temp → rename), which kills an fd
watch after the first external save because the watched inode is unlinked.
`NSFilePresenter` watches the URL, handles atomic replace / rename / move /
delete, provides coordinated reads and writes (no reading a half-written
file), and is the sandbox-sanctioned approach.

## Components

### `MarkdownFileSession` (new file)

`NSObject` conforming to `NSFilePresenter`. Owns the live connection to one
file.

State:
- `private(set) var url: URL` — current file URL; updated on rename/move.
- `private let isScoped: Bool` — whether we hold a security scope to release.
- `presentedItemURL: URL?` → returns `url`.
- `presentedItemOperationQueue: OperationQueue` → a dedicated serial queue.
- `private var lastSyncedContent: String` — the content we last read from or
  wrote to disk; used to suppress self-write echoes and reload loops.
- `var onExternalChange: ((String) -> Void)?` — invoked on the main thread
  with new disk content (external → editor direction).
- `var onMoved: ((URL) -> Void)?`, `var onDeleted: (() -> Void)?`.

Methods:
- `init(url:)` — calls `startAccessingSecurityScopedResource()` and records
  the result in `isScoped`.
- `start() -> String?` — `NSFileCoordinator.addFilePresenter(self)`,
  coordinated-read the initial content, set `lastSyncedContent`, return it.
- `write(_ content:)` — skip if `content == lastSyncedContent`; otherwise
  coordinated-write (as our own presenter, so our write does not trigger our
  own change callback) and update `lastSyncedContent`.
- `presentedItemDidChange()` — coordinated-read; if the result equals
  `lastSyncedContent`, ignore (it was our own write or a no-op); otherwise
  update `lastSyncedContent` and call `onExternalChange` on the main thread.
- `presentedItemDidMove(to:)` — update `url`, call `onMoved`.
- `accommodatePresentedItemDeletion(completionHandler:)` — call `onDeleted`,
  then `stop()`, then complete.
- `stop()` — `NSFileCoordinator.removeFilePresenter(self)`; if `isScoped`,
  `stopAccessingSecurityScopedResource()`. Idempotent.

Threading: presenter callbacks arrive on `presentedItemOperationQueue`; all
view-model/UI updates are dispatched to the main thread.

### `EditorViewModel` (changes)

- Becomes a shared singleton (`EditorViewModel.shared`), mirroring
  `AppRouter.shared`, so both the Finder open path and Home funnel into the
  same instance.
- `private var session: MarkdownFileSession?`.
- A Combine pipeline debounces `$markdownContent` (~0.6s) and calls
  `session?.write(_:)` — the editor → file direction. Independent of the
  existing 300ms preview debounce in `EditorView`.
- `func open(url:)`:
  1. tear down any existing session,
  2. create `MarkdownFileSession(url:)`, `start()`, set `markdownContent` to
     the loaded text,
  3. wire `onExternalChange` to replace `markdownContent` on the main thread,
  4. wire `onMoved` (session follows the file) and `onDeleted` (see edge
     cases).
- `func closeSession()` — `session?.stop(); session = nil`.

When `onExternalChange` replaces `markdownContent`, the debounced writer will
fire with content equal to disk; `write(_:)` skips it via the
`lastSyncedContent` guard, so there is no echo.

### `md2pdfApp` (changes)

- `handleOpenedFile(at:)` → `editorVM.open(url:)`, reset `router.path`,
  navigate to `.editor`. Remove the read-and-discard plus
  start/`defer`-stop security-scope dance (the session owns the scope now).
- Use `EditorViewModel.shared` for the scene's editor view model.
- Remove the now-dead `onAppear` block that copied
  `homeVM.markdownContent` into `editorVM`.

### `HomeView` (changes)

- `onFileUploaded(url:)` → `EditorViewModel.shared.open(url:)` then
  `appRouter.navigate(to: .editor)`, instead of reading into
  `homeVM.markdownContent`. Applies to both "Select File" and drag-drop.

### `EditorView` (changes)

- `.onDisappear { viewModel.closeSession() }` so leaving the editor releases
  the security scope and unregisters the presenter.

## Edge cases

- **External delete:** stop the session (so we stop writing to a vanished
  path) but keep the current text in the editor — the user does not lose
  work, and can Save-as-PDF or re-open.
- **External rename/move:** follow the new URL via `presentedItemDidMove`, so
  subsequent writes go to the right place.
- **Self-write echo / reload loop:** prevented by the `lastSyncedContent`
  equality guard in both `write(_:)` and `presentedItemDidChange()`.
- **Non-security-scoped URLs** (some drag/select cases): `isScoped` is
  `false`, nothing to release; reads/writes still work as they do today.

## Out of scope

- Persisting access across app launches (security-scoped bookmarks).
- Writing "Create New" documents to a `.md` file (no source file exists).
- Conflict-merge UI — external changes simply win.
