// swift-tools-version:6.0
import PackageDescription

/// `ZPDFRasterAnalysis` — automation on scanned sheets (NL-AUTO-14).
///
/// A scanned sheet has no vector linework, so Vector Snap, auto-trace and the symbol matcher have
/// nothing to read. This package reads the pixels instead, on this Mac, with no model and no
/// network: straight linework recovered from the raster becomes *proxy* primitives (confidence
/// 0.4, layer "scan") that the region tracer walks exactly as it walks vector lines, and a boxed
/// symbol is found again by normalised cross-correlation at the four right angles and their
/// mirrors. Nothing here produces a snap target (spec 17.3 keeps recogniser geometry out of
/// snap) and nothing here commits a quantity: every result is a proposal marked "from the scan".
/// Portable (macOS and iOS): CoreGraphics and Accelerate only.
let package = Package(
    name: "ZPDFRasterAnalysis",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFRasterAnalysis", targets: ["ZPDFRasterAnalysis"])
    ],
    dependencies: [
        .package(path: "../ZPDFVectorExtraction"),
        // Test-only: the region tracer, for the scan-against-vector trace benchmark.
        .package(path: "../ZPDFSnapEngine"),
        .package(path: "../ZPDFContracts")
    ],
    targets: [
        .target(
            name: "ZPDFRasterAnalysis",
            dependencies: [.product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFRasterAnalysisTests",
            dependencies: ["ZPDFRasterAnalysis", .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction"),
                           .product(name: "ZPDFSnapEngine", package: "ZPDFSnapEngine"),
                           .product(name: "ZPDFContracts", package: "ZPDFContracts")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
