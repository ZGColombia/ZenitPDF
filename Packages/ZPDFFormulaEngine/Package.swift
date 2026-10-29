// swift-tools-version:6.0
import PackageDescription

/// `ZPDFFormulaEngine` is the dimension-safe formula engine behind ledger custom columns
/// (spec 15.3, 15.4).
///
/// It depends on `ZPDFContracts` and on nothing else: no remote SwiftPM packages, and no
/// `ZPDFUI*` package. The dependency direction is UI -> core, never core -> UI.
let package = Package(
    name: "ZPDFFormulaEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFFormulaEngine", targets: ["ZPDFFormulaEngine"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts")
    ],
    targets: [
        .target(
            name: "ZPDFFormulaEngine",
            dependencies: ["ZPDFContracts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFFormulaEngineTests",
            dependencies: ["ZPDFFormulaEngine", "ZPDFContracts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
