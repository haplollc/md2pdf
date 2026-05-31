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
