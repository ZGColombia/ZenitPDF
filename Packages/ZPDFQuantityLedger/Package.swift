// swift-tools-version:6.0
import PackageDescription

/// `ZPDFQuantityLedger` is the aggregation core of the Quantity Ledger (spec 15.1, 15.5, 15.6,
/// 15.8) and the third of the three critical areas in `Docs/Execution/QUALITY_BAR.md`.
///
/// It owns the row model, grouping, totals, filtering, sorting, formula binding, change
/// propagation and the export-ready report projection. It is the engine, not the view: it
/// depends on `ZPDFContracts` and `ZPDFFormulaEngine` and on nothing else — no AppKit, no
/// SwiftUI, no `ZPDFUI*`. The dependency direction is UI -> core, never core -> UI.
let package = Package(
    name: "ZPDFQuantityLedger",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFQuantityLedger", targets: ["ZPDFQuantityLedger"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFFormulaEngine")
    ],
    targets: [
        .target(
            name: "ZPDFQuantityLedger",
            dependencies: ["ZPDFContracts", "ZPDFFormulaEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFQuantityLedgerTests",
            dependencies: ["ZPDFQuantityLedger", "ZPDFContracts", "ZPDFFormulaEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
