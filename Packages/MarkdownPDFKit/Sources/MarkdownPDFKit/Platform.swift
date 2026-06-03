//
//  Platform.swift
//  MarkdownPDFKit
//
//  Cross-platform shims so the rendering engine compiles and runs on both
//  macOS (AppKit) and iOS (UIKit). The bitmap/image type differs between
//  the two — `NSImage` vs `UIImage` — so we funnel every image through a
//  single `PlatformImage` alias and provide the handful of constructors the
//  engine needs (`Image(platformImage:)`, decoding from `Data`).
//

import SwiftUI

#if canImport(UIKit)
import UIKit
/// The platform's bitmap image type: `UIImage` on iOS, `NSImage` on macOS.
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
/// The platform's bitmap image type: `UIImage` on iOS, `NSImage` on macOS.
public typealias PlatformImage = NSImage
#endif

public extension Image {
    /// Build a SwiftUI `Image` from a `PlatformImage`, picking the correct
    /// platform initializer.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

public extension PlatformImage {
    /// Returns a copy scaled (down) so its width is at most `maxWidth`,
    /// preserving aspect ratio. Used to physically shrink wide diagrams to the
    /// column width before display — SwiftUI's image layout doesn't reliably
    /// constrain block-image width inside MarkdownUI, so we resize the bitmap
    /// itself, which can't overflow.
    func scaledDown(toWidth maxWidth: CGFloat) -> PlatformImage {
        guard size.width > maxWidth, maxWidth > 0, size.width > 0 else { return self }
        let newSize = CGSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        let image = NSImage(size: newSize)
        image.lockFocus()
        self.draw(in: CGRect(origin: .zero, size: newSize))
        image.unlockFocus()
        return image
        #endif
    }
}
