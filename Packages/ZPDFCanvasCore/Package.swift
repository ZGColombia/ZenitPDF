// swift-tools-version:6.0
import PackageDescription

/// `ZPDFCanvasCore` is the canvas's portable half (NL-PLAT-17): the arithmetic the Mac canvas
/// draws with, kept free of AppKit so an iPad canvas can draw with the same numbers.
///
/// - `PageDisplayTransform` — page space to the rotated, cropped display space and back.
/// - `ZoomMath` — zoom to a rectangle, zoom about the pointer, the page's axes on a turned sheet.
/// - `ViewportRasterPlanner` — which part of a page to rasterise, at what resolution, within budget.
/// - `AreaPillLayout`, `DimensionGrammar` — where an area's value pill and a dimension's text sit.
///
/// Moved out of `Apps/ZenitPDF/Sources/ZenitPDFAppKit/Canvas` unchanged apart from access
/// modifiers; the application re-exports this module, so its callers and tests read as before.
let package = Package(
    name: "ZPDFCanvasCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFCanvasCore", targets: ["ZPDFCanvasCore"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFPDFKitBridge")
    ],
    targets: [
        .target(
            name: "ZPDFCanvasCore",
            dependencies: [
                .product(name: "ZPDFUIPresentation", package: "ZPDFUIPresentation"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFCanvasCoreTests",
            dependencies: ["ZPDFCanvasCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
