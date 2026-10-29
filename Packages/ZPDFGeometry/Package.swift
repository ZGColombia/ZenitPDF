// swift-tools-version:6.0
import PackageDescription

/// `ZPDFGeometry` is the headless computational-geometry core of Zenit PDF.
///
/// It owns four things: the view <-> page coordinate conversion (spec 9.2/9.3), polygon and
/// segment mathematics used by the measurement engine (spec 12), the packed R-tree that backs the
/// per-page snap index (spec 13.5), and the application of a `ScaleTransform` to page geometry
/// including Scale Region ownership resolution (spec 10.4).
///
/// The package deliberately has **no PDFKit and no AppKit dependency**: every transform input is
/// a parameter, so the whole surface is testable headless. Its only dependency is the frozen
/// vocabulary in `ZPDFContracts`. The dependency direction is UI -> core, never core -> UI, so
/// nothing here may ever import a `ZPDFUI*` package.
let package = Package(
    name: "ZPDFGeometry",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFGeometry", targets: ["ZPDFGeometry"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts")
    ],
    targets: [
        .target(
            name: "ZPDFGeometry",
            dependencies: [.product(name: "ZPDFContracts", package: "ZPDFContracts")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFGeometryTests",
            dependencies: ["ZPDFGeometry"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
