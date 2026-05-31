//
//  CapsuleButtonStyle.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
    var backgroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.headline)
            .fontWeight(.bold)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(backgroundColor)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Capsule text-button style that uses Liquid Glass on iOS/macOS 26+ and
/// falls back to a solid-fill capsule (the original `CapsuleButtonStyle`
/// look) on earlier OSes. Pass `tint` for primary actions; leave it nil for
/// a neutral glass / `fallbackBackground`-filled secondary button.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color?
    var fallbackBackground: Color

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.headline)
            .fontWeight(.bold)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

        return Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                label
                    .foregroundColor(tint == nil ? .primary : .white)
                    .glassEffect(tint == nil ? .regular : .regular.tint(tint!), in: .capsule)
            } else {
                label
                    .foregroundColor(.white)
                    .background(fallbackBackground)
                    .clipShape(Capsule())
            }
        }
        .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

extension View {
    /// Background treatment for the circular icon buttons (back / refresh):
    /// Liquid Glass circle on 26+, the original `ultraThickMaterial` circle
    /// otherwise.
    @ViewBuilder func glassIconBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(in: .circle)
        } else {
            self
                .background(.ultraThickMaterial)
                .clipShape(Circle())
        }
    }
}
