// swift-tools-version:6.0
import PackageDescription

/// `ZPDFUILedger` is the Quantity Ledger UX package (gate G14).
///
/// It owns the virtualised AppKit table, the column / grouping / filter / bulk-edit
/// surfaces, and the canvas selection-sync behaviour. Everything it renders comes from
/// `LedgerPresenting` in `ZPDFUIPresentation`; everything it draws uses tokens from
/// `ZPDFDesignSystem`. There are no remote dependencies.
///
/// The test target alone also depends on `ZPDFQuantityLedger` (loop iteration 1, R-123 and
/// R-126). Tests that used to exercise this package's duplicate formula engine and filter
/// evaluator now exercise the live ones — the ledger core, its formula engine and its
/// filter — which that package links. The library's own dependencies are unchanged: the
/// UI still reaches the core only through `LedgerPresenting`.
let package = Package(
    name: "ZPDFUILedger",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFUILedger", targets: ["ZPDFUILedger"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFDesignSystem"),
        .package(path: "../ZPDFQuantityLedger")
    ],
    targets: [
        .target(
            name: "ZPDFUILedger",
            dependencies: ["ZPDFUIPresentation", "ZPDFDesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFUILedgerTests",
            dependencies: [
                "ZPDFUILedger", "ZPDFUIPresentation", "ZPDFDesignSystem",
                .product(name: "ZPDFQuantityLedger", package: "ZPDFQuantityLedger")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
