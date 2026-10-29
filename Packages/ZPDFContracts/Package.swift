// swift-tools-version:6.0
import PackageDescription

/// `ZPDFContracts` is the frozen domain vocabulary of Zenit PDF.
///
/// Every later package — the PDF engine, the measurement engine, the snap index, the ledger,
/// the persistence layer and the UI surfaces — binds to the types declared here. The package
/// therefore has **no dependencies at all**: no remote SwiftPM packages, and no dependency on
/// any `ZPDFUI*` package. The dependency direction is UI -> core, never core -> UI.
///
/// The `zpdf-contract-freeze` executable serialises the contract catalogue to
/// `Docs/Contracts/*.json`. Those JSON documents are the machine-readable freeze; this source
/// is their single origin.
let package = Package(
    name: "ZPDFContracts",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFContracts", targets: ["ZPDFContracts"]),
        .executable(name: "zpdf-contract-freeze", targets: ["ZPDFContractFreeze"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ZPDFContracts",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ZPDFContractFreeze",
            dependencies: ["ZPDFContracts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFContractsTests",
            dependencies: ["ZPDFContracts"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
