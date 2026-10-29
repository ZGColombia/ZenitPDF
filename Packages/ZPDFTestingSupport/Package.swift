// swift-tools-version:6.0
import PackageDescription

/// `ZPDFTestingSupport` is the synthetic PDF fixture corpus (gate G02).
///
/// It generates real, byte-level-controlled PDF files together with a manifest that
/// states, in exact numbers, what was drawn: every path, its page-space coordinates,
/// its length and its enclosed area. Downstream IO, geometry, snap and measurement
/// tests assert against the manifest rather than re-deriving the truth.
///
/// The package has no remote dependencies and does not depend on any other Zenit
/// package, so it can be pulled into any test target without creating a cycle.
let package = Package(
    name: "ZPDFTestingSupport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFTestingSupport", targets: ["ZPDFTestingSupport"])
    ],
    targets: [
        .target(
            name: "ZPDFTestingSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFTestingSupportTests",
            dependencies: ["ZPDFTestingSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
