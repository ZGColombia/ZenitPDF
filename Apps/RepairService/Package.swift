// swift-tools-version:6.0
import PackageDescription

/// The out-of-process structural-repair worker.
///
/// This target is a thin `main.swift`: everything it does lives in
/// `ZPDFRepairServiceCore` inside `Packages/ZPDFServiceClient`, where the tests
/// are. `Scripts/build-app.sh` builds this executable and wraps it into
/// `RepairService.xpc` inside `Zenit PDF.app/Contents/XPCServices/`, sandboxed
/// with no network and no user-selected-file entitlement — the document arrives
/// as an inherited read-only descriptor over the connection.
let package = Package(
    name: "RepairServiceApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RepairService", targets: ["RepairService"])
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFServiceClient")
    ],
    targets: [
        .executableTarget(
            name: "RepairService",
            dependencies: [
                .product(name: "ZPDFRepairServiceCore", package: "ZPDFServiceClient")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
