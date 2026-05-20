//
//  EmbeddedImageProvider.swift
//  swift-markdown-ui
//
//  Created by Jared Cassoutt on 3/22/25.
//

import SwiftUI

public protocol EmbeddedImageProvider {

  @ViewBuilder func makeImage(data: Data) -> Image
}
