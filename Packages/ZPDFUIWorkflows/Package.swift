// swift-tools-version:6.0
import PackageDescription

/// `ZPDFUIWorkflows` is the gate G15 workflow layer of Zenit PDF.
///
/// It holds the multi-step, multi-panel surfaces that sit above the single-purpose
/// controls in `ZPDFDesignSystem`: the Tool Library, search and OCR, Split Canvas,
/// Revision Compare, Revision Overlay, first-run onboarding, and the user-facing error
/// vocabulary the whole app presents failures through.
///
/// Every view binds to a presenter protocol from `ZPDFUIPresentation`, never to a concrete
/// engine, so the package builds and previews without the core engines. The package has
/// zero remote dependencies.
let package = Package(
    name: "ZPDFUIWorkflows",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFUIWorkflows", targets: ["ZPDFUIWorkflows"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFDesignSystem")
    ],
    targets: [
        .target(
            name: "ZPDFUIWorkflows",
            dependencies: ["ZPDFUIPresentation", "ZPDFDesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFUIWorkflowsTests",
            dependencies: ["ZPDFUIWorkflows", "ZPDFUIPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
