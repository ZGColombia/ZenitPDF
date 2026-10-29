// swift-tools-version:6.0
import PackageDescription

/// `ZPDFMeasurementEngine` is the calculation core behind every measurement tool in spec 12.
///
/// It owns one implementation of ``MeasurementCalculating`` per tool in spec 12.1, the cutout
/// boolean pipeline that turns an outer ring and a set of holes into a net area through
/// Clipper2, and the count aggregation in spec 12.13.
///
/// Dependencies are `ZPDFContracts` (frozen vocabulary), `ZPDFGeometry` (page-space maths and
/// scale application) and the vendored `Clipper2Bridge`. No remote SwiftPM package, no PDFKit,
/// no AppKit, and no `ZPDFUI*` package: the dependency direction is UI -> core, never core -> UI.
let package = Package(
    name: "ZPDFMeasurementEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFMeasurementEngine", targets: ["ZPDFMeasurementEngine"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFGeometry"),
        .package(path: "../../Bridges/Clipper2Bridge")
    ],
    targets: [
        .target(
            name: "ZPDFMeasurementEngine",
            dependencies: [
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry"),
                .product(name: "ZPDFClipper2", package: "Clipper2Bridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFMeasurementEngineTests",
            dependencies: ["ZPDFMeasurementEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
