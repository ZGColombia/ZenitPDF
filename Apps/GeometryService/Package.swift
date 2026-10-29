// swift-tools-version:6.0
import PackageDescription

/// The out-of-process vector-extraction worker.
///
/// This target is a thin `main.swift`: everything it does lives in
/// `ZPDFGeometryServiceCore` inside `Packages/ZPDFServiceClient`, where the tests
/// are. `Scripts/build-app.sh` builds this executable and wraps it into
/// `GeometryService.xpc` inside `Zenit PDF.app/Contents/XPCServices/`, sandboxed
/// with no network and no user-selected-file entitlement — the document arrives
/// as an inherited read-only descriptor over the connection.
let package = Package(
    name: "GeometryServiceApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GeometryService", targets: ["GeometryService"])
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFServiceClient")
    ],
    targets: [
        .executableTarget(
            name: "GeometryService",
            dependencies: [
                .product(name: "ZPDFGeometryServiceCore", package: "ZPDFServiceClient")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
