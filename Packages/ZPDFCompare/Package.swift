// swift-tools-version:6.0
import PackageDescription

/// `ZPDFCompare` is Revision Compare and Revision Overlay.
///
/// Two questions, answered separately and never conflated:
///
/// 1. **Where do the pixels differ?** Both revisions are rasterised through
///    `ZPDFPDFKitBridge`, the revision is warped into the baseline's frame by an
///    alignment transform, and the per-pixel difference is grouped into connected
///    regions. This signal is honest about what it is: a *pixel* difference, which on a
///    CAD sheet is as easily a re-plot artefact as a design change.
/// 2. **What geometry changed?** When both pages carry vector content, the primitives
///    extracted by `ZPDFVectorExtraction` are matched shape by shape, so a line that
///    moved 3 mm is reported as one moved line rather than as two clouds of pixels.
///
/// The two signals are carried in separate fields of ``RevisionComparisonResult`` and
/// tagged with ``DifferenceSignal``. Nothing in this package ever presents a raster
/// difference as a geometry change.
///
/// No OpenCV. The optional automatic alignment path uses Vision's image registration,
/// and a Vision failure is a normal outcome that falls back to manual alignment — never
/// a thrown error.
///
/// No AppKit and no SwiftUI: compositing is CoreGraphics, registration is Vision, and
/// every value that crosses an actor boundary is `Sendable`.
let package = Package(
    name: "ZPDFCompare",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFCompare", targets: ["ZPDFCompare"])
    ],
    dependencies: [
        .package(path: "../ZPDFPDFKitBridge"),
        .package(path: "../ZPDFVectorExtraction"),
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFCompare",
            dependencies: [
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFCompareTests",
            dependencies: [
                "ZPDFCompare",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
