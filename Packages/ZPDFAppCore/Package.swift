// swift-tools-version:6.0
import PackageDescription

/// `ZPDFAppCore` binds the real engines to the UI presenter protocols.
///
/// `ZPDFUIPresentation` declares what the UI observes; the engine packages compute the
/// numbers. Neither knows about the other, and that is deliberate: the UI was written
/// against mock presenters before the engines existed, and the engines are pure value
/// code with no view state. This package is the seam where the two meet, and it is the
/// only place in the product that is allowed to know both vocabularies.
///
/// Three rules hold everywhere inside it:
///
/// 1. **Engines run off the main actor.** ``TakeoffSession`` is an `actor`; every engine
///    call happens inside it. Presenters are `@MainActor` and receive `Sendable` snapshots.
/// 2. **Nothing blocks the main thread.** A presenter method returns immediately and the
///    result arrives through an awaited snapshot. Long operations report progress and are
///    cancellable.
/// 3. **Rows are addressed by index.** No presenter publishes a materialised row array
///    (ADR-0003 §3.4).
let package = Package(
    name: "ZPDFAppCore",
    // Portable in practice since before 2026-09-23 (zero AppKit; it compiled for iOS in a scratch
    // copy), and on paper since NL-PLAT-17, so `Scripts/verify-multiplatform.sh` gates it.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFAppCore", targets: ["ZPDFAppCore"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFGeometry"),
        .package(path: "../ZPDFMeasurementEngine"),
        .package(path: "../ZPDFQuantityLedger"),
        .package(path: "../ZPDFFormulaEngine"),
        .package(path: "../ZPDFSnapEngine"),
        .package(path: "../ZPDFVectorExtraction"),
        .package(path: "../ZPDFPDFKitBridge"),
        .package(path: "../ZPDFSearch"),
        .package(path: "../ZPDFPersistence"),
        .package(path: "../ZPDFCompare"),
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFCollaboration"),
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFAppCore",
            dependencies: [
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry"),
                .product(name: "ZPDFMeasurementEngine", package: "ZPDFMeasurementEngine"),
                .product(name: "ZPDFQuantityLedger", package: "ZPDFQuantityLedger"),
                // NL-QTY-07 round 2: office-library assembly recipes are the engine's own type.
                .product(name: "ZPDFFormulaEngine", package: "ZPDFFormulaEngine"),
                .product(name: "ZPDFSnapEngine", package: "ZPDFSnapEngine"),
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFSearch", package: "ZPDFSearch"),
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                .product(name: "ZPDFCompare", package: "ZPDFCompare"),
                .product(name: "ZPDFUIPresentation", package: "ZPDFUIPresentation"),
                // NL-COLLAB-12, ADR-0026: the Shared Review Folder's log and merge.
                .product(name: "ZPDFCollaboration", package: "ZPDFCollaboration")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFAppCoreTests",
            dependencies: [
                "ZPDFAppCore",
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                .product(name: "ZPDFCollaboration", package: "ZPDFCollaboration"),
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
