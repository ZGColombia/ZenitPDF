// swift-tools-version:6.0
import PackageDescription

/// `ZPDFExtensions` — declarative packs (NL-PLAT-23, phase 1).
///
/// A `.zpdfpack` is a zip of Zenit's own data files — tool sets, job templates and export
/// profiles — with a `pack.json` manifest. Nothing in a pack executes: this package reads the
/// container, refuses anything that is not one of those data files, and hands each file's bytes
/// to the importer that already validates that format. A script host (phase 2) is not built and
/// needs its own ADR. Portable (macOS and iOS); no dependency outside the repository.
let package = Package(
    name: "ZPDFExtensions",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFExtensions", targets: ["ZPDFExtensions"])
    ],
    dependencies: [
        .package(path: "../ZPDFSpreadsheet")
    ],
    targets: [
        .target(
            name: "ZPDFExtensions",
            dependencies: [.product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFExtensionsTests",
            dependencies: ["ZPDFExtensions", .product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
