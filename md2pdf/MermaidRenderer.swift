//
//  MermaidRenderer.swift
//  md2pdf
//
//  Renders ```mermaid``` code blocks into NSImages so they can be embedded
//  into the exported PDF. Loads `mermaid.min.js` *bundled into the app*
//  inside an offscreen WKWebView, calls `mermaid.render()` for each
//  diagram, and snapshots the resulting <svg> bounding rect.
//
//  Why a web view? Mermaid is a JavaScript library that compiles diagram
//  source into SVG. There's no actively maintained native Swift port; the
//  layout for flowcharts / sequence / class diagrams is non-trivial.
//
//  Why bundled and not CDN? CDN loads were the dominant source of test
//  flakiness — the first WKWebView in a run had to do a fresh download
//  every time, and the 10s timeout would occasionally fire before mermaid
//  finished initializing under load. Bundling adds ~3MB to the app but
//  makes rendering deterministic and offline-safe.
//
//  Why an offscreen NSWindow? WKWebView's rendering pipeline doesn't
//  flush layout reliably when the view isn't part of a window hierarchy.
//  Attaching to a borderless offscreen window — the same trick we use
//  for SwiftUI preference resolution — fixes intermittent missing /
//  half-rendered diagrams.
//
//  Why batch through a single WKWebView? Booting the harness once and
//  calling `mermaid.render(id, code)` per diagram is ~10× faster than
//  per-diagram WebView setup and avoids re-paying initialization cost.
//

import WebKit
import AppKit

@MainActor
final class MermaidRenderer {

    /// Boots a single mermaid-loaded WebView, renders each diagram once,
    /// and tears the page down. Duplicate diagram source strings are
    /// rendered only once. Diagrams whose render fails are skipped — the
    /// caller will fall back to plain code fences.
    static func renderAll(_ codes: [String]) async -> [String: NSImage] {
        guard !codes.isEmpty else { return [:] }
        let unique = Array(Set(codes))

        let renderer = MermaidRenderer()
        guard await renderer.boot() else {
            await renderer.shutdown()
            return [:]
        }

        var cache: [String: NSImage] = [:]
        for code in unique {
            if let img = await renderer.render(code) {
                cache[code] = img
            }
        }
        await renderer.shutdown()
        return cache
    }

    /// Single-diagram convenience.
    static func render(_ code: String) async -> NSImage? {
        let renderer = MermaidRenderer()
        guard await renderer.boot() else {
            await renderer.shutdown()
            return nil
        }
        let img = await renderer.render(code)
        await renderer.shutdown()
        return img
    }

    // MARK: - Implementation

    private var webView: WKWebView?
    private var window: NSWindow?
    private var navigationDelegate: NavigationDelegate?

    /// Booting = create the WebView, attach it to an offscreen NSWindow,
    /// load the mermaid harness HTML, and wait until `window.mermaidReady`
    /// flips to `true`. Returns false if mermaid never loaded (e.g. network
    /// down) within a generous timeout.
    private func boot() async -> Bool {
        let frame = NSRect(x: 0, y: 0, width: 2000, height: 2000)
        let config = WKWebViewConfiguration()
        // Defaults are fine — JS is enabled by default in WKWebView.
        let webView = WKWebView(frame: frame, configuration: config)
        // Transparent so it doesn't punch a white rect through our snapshot.
        webView.setValue(false, forKey: "drawsBackground")

        // Offscreen window so WebKit's renderer actually lays out the SVG.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView

        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        self.webView = webView
        self.window = window
        self.navigationDelegate = delegate

        // Wait for the harness page to finish loading.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { cont.resume() }
            webView.loadHTMLString(harnessHTML, baseURL: URL(string: "https://localhost/"))
        }

        // Then poll until mermaid.js itself has finished downloading from
        // the CDN and initialized.
        for _ in 0..<100 { // up to ~10s
            try? await Task.sleep(nanoseconds: 100_000_000)
            let ready = (try? await webView.evaluateJavaScript("window.mermaidReady === true")) as? Bool
            if ready == true { return true }
        }
        return false
    }

    /// Render one diagram. The harness page exposes
    /// `window.renderDiagram(code)` which awaits `mermaid.render(…)`,
    /// mounts the SVG into the DOM, and returns its bounding rect as JSON.
    /// We must use `callAsyncJavaScript` (not `evaluateJavaScript`) because
    /// the harness function is `async` and the latter does not unwrap
    /// Promises — it would hand us back the Promise object itself.
    private func render(_ code: String) async -> NSImage? {
        guard let webView else { return nil }

        let body = "return await window.renderDiagram(code);"
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                body,
                arguments: ["code": code],
                contentWorld: .page
            )
        } catch {
            return nil
        }

        guard let rectJSON = raw as? String,
              !rectJSON.isEmpty,
              !rectJSON.hasPrefix("ERROR")
        else { return nil }

        guard
            let rectData = rectJSON.data(using: .utf8),
            let rect = try? JSONDecoder().decode(Rect.self, from: rectData),
            rect.w > 1, rect.h > 1
        else { return nil }

        // One more runloop turn after the JS resolves — gives the layer
        // tree a chance to paint before we snapshot.
        try? await Task.sleep(nanoseconds: 50_000_000)

        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
            // Ask for the snapshot at the same point-size as the SVG; WebKit
            // will produce a 2x-backed image on Retina hardware automatically.
            snapConfig.snapshotWidth = NSNumber(value: Double(rect.w))
            webView.takeSnapshot(with: snapConfig) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    private func shutdown() async {
        window?.contentView = nil
        window?.close()
        window = nil
        webView = nil
        navigationDelegate = nil
    }

    private struct Rect: Decodable { let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
            onFinish = nil
        }
    }

    // MARK: - Harness HTML

    /// The harness runs once per render session:
    ///   1. evaluates the bundled mermaid.min.js inline (no network),
    ///   2. installs `window.renderDiagram(code)` that uses
    ///      `mermaid.render(…)` (which returns a Promise with the
    ///      finalized SVG) and injects the SVG into `#mount`,
    ///   3. returns the SVG's bounding rect as a JSON string so the
    ///      Swift side can snapshot exactly the right region.
    ///
    /// We deliberately disable `startOnLoad` and drive rendering
    /// imperatively — that way our await semantics line up with the
    /// JS promise instead of racing the auto-render heuristic.
    private var harnessHTML: String {
        let mermaidJS = Self.bundledMermaidJS
        return """
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8">
            <style>
              * { box-sizing: border-box; }
              html, body { margin: 0; padding: 0; background: transparent; }
              body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
              #mount { display: inline-block; padding: 8px; background: white; }
              #mount svg { display: block; }
            </style>
            <script>\(mermaidJS)</script>
            <script>
              window.mermaidReady = false;
              window.mermaidCounter = 0;
              if (typeof mermaid !== 'undefined') {
                mermaid.initialize({
                  startOnLoad: false,
                  theme: 'default',
                  securityLevel: 'loose',
                  flowchart: { useMaxWidth: false, htmlLabels: true },
                  sequence: { useMaxWidth: false },
                });
                window.mermaidReady = true;
              }

              window.renderDiagram = async function (code) {
                try {
                  const id = 'm' + (++window.mermaidCounter);
                  const result = await mermaid.render(id, code);
                  const mount = document.getElementById('mount');
                  mount.innerHTML = result.svg;

                  // Use the SVG's intrinsic dimensions (from viewBox + max-width)
                  // to set explicit width/height so the inline-block container
                  // doesn't collapse to ~16px. Mermaid emits style="max-width:
                  // <n>px" — parse that out, and fall back to viewBox if absent.
                  const svg = mount.querySelector('svg');
                  if (svg) {
                    let w = 0, h = 0;
                    const styleMax = (svg.getAttribute('style') || '')
                      .match(/max-width:\\s*([0-9.]+)px/i);
                    if (styleMax) w = parseFloat(styleMax[1]);
                    const vb = svg.getAttribute('viewBox');
                    if (vb) {
                      const parts = vb.split(/\\s+/).map(parseFloat);
                      if (parts.length === 4) {
                        if (!w) w = parts[2];
                        h = parts[3] * (w / parts[2]);
                      }
                    }
                    if (w > 0 && h > 0) {
                      svg.setAttribute('width', w);
                      svg.setAttribute('height', h);
                      svg.style.maxWidth = w + 'px';
                    }
                  }
                  // Force a synchronous layout flush before reading the rect.
                  void mount.offsetWidth;
                  const r = mount.getBoundingClientRect();
                  return JSON.stringify({
                    x: Math.floor(r.left),
                    y: Math.floor(r.top),
                    w: Math.ceil(r.width),
                    h: Math.ceil(r.height),
                  });
                } catch (e) {
                  return 'ERROR: ' + (e && e.message ? e.message : String(e));
                }
              };
            </script>
          </head>
          <body>
            <div id="mount"></div>
          </body>
        </html>
        """
    }

    /// Reads `mermaid.min.js` once from the app bundle and caches the bytes.
    /// Inlining a 3MB string into each harness HTML is fine — it's a one-
    /// shot load per render session — but reading the file again every
    /// time would be wasteful.
    private static let bundledMermaidJS: String = {
        if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }
        return "/* mermaid.min.js not found in bundle */"
    }()
}
