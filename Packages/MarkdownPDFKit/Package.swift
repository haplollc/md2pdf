// swift-tools-version:5.9
//
//  MarkdownPDFKit — turn Markdown into paginated, pixel-accurate PDFs.
//  The rendering engine behind the md2pdf app, also exposed as a CLI.
//

import PackageDescription

let package = Package(
  name: "MarkdownPDFKit",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(name: "MarkdownPDFKit", targets: ["MarkdownPDFKit"]),
    .executable(name: "md2pdf-cli", targets: ["md2pdf-cli"]),
  ],
  dependencies: [
    .package(path: "../Markdown"),
  ],
  targets: [
    .target(
      name: "MarkdownPDFKit",
      dependencies: [
        .product(name: "Markdown", package: "Markdown"),
      ],
      resources: [
        .copy("Resources/mermaid.min.js"),
      ]
    ),
    .executableTarget(
      name: "md2pdf-cli",
      dependencies: ["MarkdownPDFKit"]
    ),
  ]
)
