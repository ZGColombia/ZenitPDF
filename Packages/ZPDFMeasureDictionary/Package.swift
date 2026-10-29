// swift-tools-version:6.0
import PackageDescription

/// `ZPDFMeasureDictionary` reads the scale a CAD program already wrote into a PDF (NL-PLAT-06):
/// the page's `/VP` viewports and their `/Measure` rectilinear dictionaries (ISO 32000-1 §12.9),
/// turned into metres per point. Read-only, CoreGraphics only, portable.
let package = Package(
    name: "ZPDFMeasureDictionary",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFMeasureDictionary", targets: ["ZPDFMeasureDictionary"])
    ],
    targets: [
        .target(name: "ZPDFMeasureDictionary", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ZPDFMeasureDictionaryTests", dependencies: ["ZPDFMeasureDictionary"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
