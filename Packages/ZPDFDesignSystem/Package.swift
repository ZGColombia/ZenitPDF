// swift-tools-version:6.0
import PackageDescription

/// `ZPDFDesignSystem` is the Graphite Workshop design system: colour, type, spacing and motion
/// tokens, the Zenit-drawn measurement icon set, and the small AppKit/SwiftUI controls every
/// surface package composes with.
///
/// It depends on `ZPDFUIPresentation` for one reason only: the design system is the single place
/// allowed to turn a presentation value into something drawable. The presentation package stays
/// free of AppKit, and the bridge (`ColorRGBA` -> `NSColor`/`Color`, `MeasurementKind` -> icon)
/// lives here instead of being re-implemented in each surface package. The dependency is one-way;
/// nothing in `ZPDFUIPresentation` imports this package.
let package = Package(
    name: "ZPDFDesignSystem",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFDesignSystem", targets: ["ZPDFDesignSystem"]),
        .executable(name: "zpdf-design-audit", targets: ["ZPDFDesignSystemAudit"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation")
    ],
    targets: [
        .target(
            name: "ZPDFDesignSystem",
            dependencies: ["ZPDFUIPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ZPDFDesignSystemAudit",
            dependencies: ["ZPDFDesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFDesignSystemTests",
            dependencies: ["ZPDFDesignSystem", "ZPDFUIPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
