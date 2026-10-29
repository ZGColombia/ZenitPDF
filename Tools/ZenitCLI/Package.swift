// swift-tools-version:6.0
import PackageDescription

/// `zenit` — the headless, read-only command-line tool (NL-PLAT-13): totals, exports, info and an
/// integrity check of a `.zpdfproj`, computed by the same engines, ledger and exporters the app
/// uses. It opens every package read-only, so it can never race the app's writer.
let package = Package(
    name: "ZenitCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "zenit", targets: ["zenit"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFAppCore"),
        .package(path: "../../Packages/ZPDFContracts"),
        .package(path: "../../Packages/ZPDFExport"),
        .package(path: "../../Packages/ZPDFPersistence"),
        .package(path: "../../Packages/ZPDFTestingSupport"),
        // Test-only: the Tool Library's file format, for the schema conformance test (NL-PLAT-14),
        // and the pack container.
        .package(path: "../../Packages/ZPDFUIWorkflows"),
        .package(path: "../../Packages/ZPDFExtensions"),
        .package(path: "../../Packages/ZPDFSpreadsheet"),
    ],
    targets: [
        .target(
            name: "ZenitCLICore",
            dependencies: [
                .product(name: "ZPDFAppCore", package: "ZPDFAppCore"),
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFExport", package: "ZPDFExport"),
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "zenit", dependencies: ["ZenitCLICore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "ZenitCLITests",
            dependencies: [
                "ZenitCLICore",
                // The executable itself, so the end-to-end test runs `zenit totals --json` as a person would.
                "zenit",
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                .product(name: "ZPDFAppCore", package: "ZPDFAppCore"),
                .product(name: "ZPDFExport", package: "ZPDFExport"),
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport"),
                .product(name: "ZPDFUIWorkflows", package: "ZPDFUIWorkflows"),
                .product(name: "ZPDFExtensions", package: "ZPDFExtensions"),
                .product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
