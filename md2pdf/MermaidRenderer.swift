//
//  MermaidRenderer.swift
//  md2pdf
//
//  Renders ```mermaid``` code blocks into NSImages so they can be embedded
//  into the exported PDF. Loads mermaid.js from a CDN inside an offscreen
//  WKWebView, evaluates `mermaid.render(…)` to produce SVG, and snapshots
//  the rendered <svg> bounding rect.
//
//  Why a web view? Mermaid is a JavaScript library that compiles diagram
//  source into SVG. There's no actively maintained native Swift port, and
//  re-implementing flowchart / sequence / class diagram layout is a
//  multi-month project. Hosting mermaid.js in WebKit is the standard
//  approach used by Obsidian, VS Code's printing extensions, etc.
//
//  We require an active network connection because mermaid is loaded from
//  jsDelivr. Offline diagrams degrade to plain code fences (the regex pre-
//  process skips mermaid blocks if rendering fails for any reason).
//

import WebKit
import AppKit

@MainActor
final class MermaidRenderer {

    /// Renders each mermaid diagram code into an NSImage. Returns a dict
    /// keyed by source code so duplicates only get rendered once. Calling
    /// with an empty array is a no-op (no WKWebView is created).
    static func renderAll(_ codes: [String]) async -> [String: NSImage] {
        guard !codes.isEmpty else { return [:] }
        let unique = Array(Set(codes))
        var cache: [String: NSImage] = [:]
        for code in unique {
            if let img = await render(code) {
                cache[code] = img
            }
        }
        return cache
    }

    /// Render a single diagram. Each call creates and tears down its own
    /// WKWebView — simpler than juggling reuse across asynchronous renders
    /// and the rendering itself is dominated by the network cost of fetching
    /// mermaid.js, which the system URL cache deduplicates.
    static func render(_ code: String) async -> NSImage? {
        let renderer = MermaidRenderer()
        return await renderer.renderOne(code)
    }

    // MARK: - Implementation

    private var webView: WKWebView?
    private var navigationDelegate: NavigationDelegate?

    private func renderOne(_ code: String) async -> NSImage? {
        // Allocate plenty of room — the final snapshot is cropped to the SVG.
        let frame = NSRect(x: 0, y: 0, width: 1600, height: 1600)
        let config = WKWebViewConfiguration()
        // Allow JS — required for mermaid to execute.
        let webView = WKWebView(frame: frame, configuration: config)
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        self.webView = webView
        self.navigationDelegate = delegate

        // 1. Wait for the page to finish loading.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.onFinish = { cont.resume() }
            webView.loadHTMLString(html(for: code), baseURL: URL(string: "https://localhost/"))
        }

        // 2. Poll until the SVG appears (mermaid renders asynchronously
        //    after page load). Bail after a generous timeout — usually
        //    the first render completes in 300–600 ms.
        let maxAttempts = 60          // ~6 seconds
        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let ready = (try? await webView.evaluateJavaScript("document.querySelector('.mermaid svg') !== null")) as? Bool
            if ready == true { break }
        }

        // 3. Read the SVG's bounding rect so we snapshot only the diagram,
        //    not the whole page padding.
        guard let rect = await readSVGBounds(in: webView) else {
            return nil
        }

        // 4. Snapshot the SVG region into an NSImage.
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = rect
            webView.takeSnapshot(with: snapConfig) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    private func readSVGBounds(in webView: WKWebView) async -> CGRect? {
        let js = """
        (function () {
          const svg = document.querySelector('.mermaid svg');
          if (!svg) return '';
          const r = svg.getBoundingClientRect();
          return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
        })();
        """
        guard
            let raw = try? await webView.evaluateJavaScript(js) as? String,
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Rect.self, from: data),
            decoded.w > 1, decoded.h > 1
        else { return nil }
        return CGRect(x: decoded.x, y: decoded.y, width: decoded.w, height: decoded.h)
    }

    private struct Rect: Decodable { let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat }

    private func html(for diagram: String) -> String {
        // Mermaid expects diagram text as raw text inside the .mermaid div.
        // No HTML escaping needed for `<` / `>` because mermaid syntax uses
        // its own tokens (`A --> B`, `Alice ->> Bob`, etc.), but we do
        // escape `&` defensively for things like edge labels.
        let safe = diagram.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8">
            <style>
              body { margin: 0; padding: 16px; background: #ffffff;
                     font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
              .mermaid { display: inline-block; }
            </style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
          </head>
          <body>
            <div class="mermaid">
        \(safe)
            </div>
            <script>
              mermaid.initialize({
                startOnLoad: true,
                theme: 'default',
                securityLevel: 'loose',
                flowchart: { useMaxWidth: false }
              });
            </script>
          </body>
        </html>
        """
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
            onFinish = nil  // guard against double-callback
        }
    }
}
