//
//  OffscreenViewHost.swift
//  MarkdownPDFKit
//
//  Hosts a SwiftUI view off-screen so it can be measured and snapshot to a
//  bitmap for the PDF renderer. This is deliberately NOT `ImageRenderer`:
//  ImageRenderer clips heading ascenders and drops syntax-highlighted code
//  blocks for our content, so we keep the faithful host-view snapshot
//  pipeline. The platform difference (AppKit `NSHostingView` in an
//  off-screen `NSWindow` vs UIKit `UIHostingController` in a hidden
//  `UIWindow`) is hidden behind this one type.
//
//  iOS note: `UIHostingController` lays out differently in vs out of a
//  window, so measurement AND snapshot must both happen with the controller
//  attached to the off-screen window — otherwise the frame height won't
//  match the actual layout and the content gets clipped top and bottom.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class OffscreenViewHost {
    private let width: CGFloat

    /// Pre-shrink factor for *Markdown block images* (`![](…)`): the image
    /// provider shrinks a too-wide bitmap to `containerWidth / rasterImageScale`
    /// so it fits the column (MarkdownUI's flow layout otherwise ignores width
    /// constraints and lets wide images overflow). Both platforms snapshot via
    /// `CALayer.render`, which draws raster images 1:1 at their point size, so
    /// the factor is 1 — shrink straight to the column width. (Mermaid diagrams
    /// don't use this path; the theme renders them directly — see
    /// `Theme+md2pdf`.)
    static let rasterImageScale: CGFloat = 1

    #if os(macOS)
    private let window: NSWindow

    init(width: CGFloat) {
        self.width = width
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
    }

    /// Lay out `view` at the host width and return its natural height.
    func measureHeight(_ view: AnyView) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return max(hosting.fittingSize.height, 1)
    }

    /// Render `view` (laid out at the host width and `height`) to a bitmap.
    func snapshot(_ view: AnyView, height: CGFloat, scale: CGFloat) -> CGImage? {
        let hosting = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: width, height: height))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting

        // The double layout + display + runloop spin gives SwiftUI (and any
        // layer-backed content) a chance to settle before we read pixels,
        // which fixes intermittent blank / half-rendered pages.
        hosting.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let layer = hosting.layer else { return nil }
        return Self.snapshot(layer: layer, width: width, height: height, scale: scale)
    }

    func teardown() {
        window.contentView = nil
        window.close()
    }

    #else
    private let window: UIWindow
    private let container: UIViewController

    init(width: CGFloat) {
        self.width = width
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let frame = CGRect(x: 0, y: 0, width: width, height: 10)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        container = UIViewController()
        window.rootViewController = container
        // In the render hierarchy (so SwiftUI actually lays out and paints)
        // but occluded behind the app's key window so the user never sees it.
        window.windowLevel = UIWindow.Level.normal - 1
        window.isHidden = false
    }

    /// Lay out `view` at the host width and return its natural height.
    func measureHeight(_ view: AnyView) -> CGFloat {
        let host = makeHostingController(view)
        attach(host)
        let height = fittingHeight(host)
        detach(host)
        return height
    }

    /// Render `view` (laid out at the host width and `height`) to a bitmap.
    /// `height` matches what `measureHeight` returned for the same content,
    /// so the frame fits the content exactly (no top/bottom clipping).
    func snapshot(_ view: AnyView, height: CGFloat, scale: CGFloat) -> CGImage? {
        let host = makeHostingController(view)
        attach(host)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Let SwiftUI settle before snapshotting.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.view.layoutIfNeeded()

        // Render via `layer.render(in:)` into a `UIGraphicsImageRenderer`
        // context — NOT `drawHierarchy`. drawHierarchy magnifies raster images
        // relative to their point size, so wide diagrams overflow and clip,
        // whereas layer rendering draws them 1:1 (exactly like macOS, which is
        // why the macOS PDF always fit). Using UIKit's own renderer context
        // (rather than a hand-rolled flipped CGContext) keeps text crisp and
        // intact — a manual context dropped glyph marks like the dot on "i".
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            host.view.layer.render(in: ctx.cgContext)
        }
        detach(host)
        return image.cgImage
    }

    func teardown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: iOS helpers

    private func makeHostingController(_ view: AnyView) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        // No window safe-area insets should shift the content.
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        return host
    }

    private func attach(_ host: UIHostingController<AnyView>) {
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
    }

    private func detach(_ host: UIHostingController<AnyView>) {
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

    /// The content's natural height, measured while attached to the window so
    /// it matches the layout used at snapshot time.
    private func fittingHeight(_ host: UIHostingController<AnyView>) -> CGFloat {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let size = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return max(size.height, 1)
    }
    #endif

    // MARK: - Shared

    /// Renders a layer tree into a white-backed RGBA bitmap (macOS path). The
    /// y-flip reconciles the bitmap context's bottom-left origin with the
    /// layer's top-left geometry. iOS renders its layer the same way but via a
    /// `UIGraphicsImageRenderer` context (see `snapshot(_:height:scale:)`).
    /// Layer rendering draws raster images at their point size — which is why
    /// wide diagrams fit instead of clipping.
    private static func snapshot(layer: CALayer, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        let pixelW = Int(width * scale)
        let pixelH = Int(height * scale)
        guard pixelW > 0, pixelH > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: pixelW, height: pixelH,
            bitsPerComponent: 8, bytesPerRow: pixelW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
