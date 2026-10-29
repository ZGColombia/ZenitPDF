// swift-tools-version:6.0
import PackageDescription

/// `ZPDFRenderer` is the markup overlay renderer of Zenit PDF.
///
/// It owns two implementations of one protocol, ``MarkupPageRendering``:
///
/// - `CoreGraphicsMarkupRenderer` — the reference implementation. Correctness first. It is the
///   oracle the Metal renderer is compared against, and the backend the factory falls back to
///   when Metal is unavailable or a shader fails to compile.
/// - `MetalMarkupRenderer` — the production renderer. Instanced lines, cached triangulated fills,
///   a count-symbol atlas and a glyph atlas, all in persistent GPU buffers with a dirty-slot
///   update path, plus a separate overlay pass for selection handles and snap feedback.
///
/// Both share one geometry front end (`RenderTransform`, `PolygonTriangulator`, `DashPattern`,
/// `GlyphAtlas`, `SymbolAtlas`) and one hit tester (`SceneHitTester`), so what is hit-tested is
/// by construction the geometry that was drawn, at the same tolerance, on either backend.
///
/// No AppKit and no SwiftUI: every view-space input is a parameter, so the whole surface renders
/// offscreen and is testable headless. The dependency direction is UI -> renderer -> core.
let package = Package(
    name: "ZPDFRenderer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFRenderer", targets: ["ZPDFRenderer"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFGeometry"),
        // Vendored Clipper2 (Boost Software Licence 1.0). Used for one thing only: repairing a
        // contour whose edges actually cross, so an even-odd fill of it is the region the rule
        // says it is rather than the contour's convex hull. See `PolygonTriangulator`.
        .package(path: "../../Bridges/Clipper2Bridge")
    ],
    targets: [
        .target(
            name: "ZPDFRenderer",
            dependencies: [
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry"),
                .product(name: "ZPDFClipper2", package: "Clipper2Bridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Deterministic synthetic scenes shared by the tests and by the golden regeneration
        // tool. Not a product: a shipping app must never link the fixture generator.
        .target(
            name: "ZPDFRendererScenario",
            dependencies: ["ZPDFRenderer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The regeneration script for Tests/ZPDFRendererGoldenTests/Goldens.
        .executableTarget(
            name: "zpdf-render-goldens",
            dependencies: ["ZPDFRenderer", "ZPDFRendererScenario"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "ZPDFRendererTests",
            dependencies: ["ZPDFRenderer", "ZPDFRendererScenario"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFRendererGoldenTests",
            dependencies: ["ZPDFRenderer", "ZPDFRendererScenario"],
            resources: [.copy("Goldens")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFRendererPerformanceTests",
            dependencies: [
                "ZPDFRenderer",
                "ZPDFRendererScenario",
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
