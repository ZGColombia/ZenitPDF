// swift-tools-version:6.0
import PackageDescription

/// `ZPDFSnapEngine` is the headless snap engine of Zenit PDF (`SNAP_CONTRACT`, `QUALITY_BAR` 3).
///
/// It owns four things: the per-page snap index built from the three geometry sources of
/// `SNAP_CONTRACT` 13.2 (extracted PDF vector primitives, Zenit markups, and boundaries), the
/// lazy derivation of snap targets inside the query radius, the candidate scoring of
/// `SNAP_CONTRACT` 13.7, and the anti-jitter and modifier state machine of 13.8/13.9.
///
/// The package has **no AppKit and no SwiftUI dependency**: every view-space input is a
/// parameter, so the whole surface is testable headless and nothing in it can reach the
/// main actor. The dependency direction is UI -> core, never core -> UI.
///
/// The test targets depend on `ZPDFTestingSupport` for the synthetic PDF corpus. The library
/// target deliberately does not: a shipping product must never link the fixture generator.
let package = Package(
    name: "ZPDFSnapEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFSnapEngine", targets: ["ZPDFSnapEngine"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFGeometry"),
        .package(path: "../ZPDFVectorExtraction"),
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFSnapEngine",
            dependencies: [
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry"),
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Synthetic scenes and pointer paths shared by the tests and by the out-of-process
        // determinism driver. Not a product: nothing outside this package links it.
        .target(
            name: "ZPDFSnapScenario",
            dependencies: ["ZPDFSnapEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Prints one snap decision log to stdout and exits. `ZPDFSnapDeterminismTests` spawns it
        // 20 times, in 20 fresh processes with randomised `Hasher` seeding, and requires
        // byte-identical output (`QUALITY_BAR` 3.4 rule 4).
        .executableTarget(
            name: "zpdf-snap-decision-log",
            dependencies: ["ZPDFSnapEngine", "ZPDFSnapScenario"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "ZPDFSnapEngineTests",
            dependencies: [
                "ZPDFSnapEngine",
                "ZPDFSnapScenario",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFSnapGoldenTests",
            dependencies: [
                "ZPDFSnapEngine",
                "ZPDFSnapScenario",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFSnapDeterminismTests",
            dependencies: ["ZPDFSnapEngine", "ZPDFSnapScenario"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFSnapFuzzTests",
            dependencies: [
                "ZPDFSnapEngine",
                "ZPDFSnapScenario",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFSnapPerformanceTests",
            dependencies: ["ZPDFSnapEngine", "ZPDFSnapScenario"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
