// swift-tools-version:6.0
import PackageDescription

/// `ZPDFVectorExtraction` turns the content stream of one PDF page into typed vector
/// geometry in canonical page space. It is the foundation of Vector Snap.
///
/// Extraction uses CoreGraphics `CGPDFScanner` only — no PDFium, no third-party PDF
/// engine, per `QUALITY_BAR.md` section 3.6. The library target has no dependency on
/// any other Zenit package: the frozen contracts in `ZPDFContracts` and the page-space
/// maths in `ZPDFGeometry` are bound to this package in a later integration pass, and
/// until then the small set of geometric value types it needs are defined here.
///
/// The test target depends on `ZPDFTestingSupport` for the synthetic PDF corpus. The
/// library target deliberately does not: a shipping product must never link the
/// fixture generator.
let package = Package(
    name: "ZPDFVectorExtraction",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFVectorExtraction", targets: ["ZPDFVectorExtraction"])
    ],
    dependencies: [
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFVectorExtraction",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFVectorExtractionTests",
            dependencies: [
                "ZPDFVectorExtraction",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The parallel-pair query budget, in a process of its own: timed beside the main
        // target's heavy suites it measured their load, not the query (I-34).
        .testTarget(
            name: "ZPDFVectorExtractionPerformanceTests",
            dependencies: ["ZPDFVectorExtraction"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
