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
