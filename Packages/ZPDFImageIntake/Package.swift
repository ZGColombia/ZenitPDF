// swift-tools-version:6.0
import PackageDescription

/// `ZPDFImageIntake` turns scanned and photographed drawings — single- and multi-page TIFF
/// (including CCITT Group 4), JPEG, PNG and HEIC — into PDF sheets at a *recorded* resolution
/// (NL-PLAT-04).
///
/// Portable by design (ImageIO + CoreGraphics only, no AppKit, no PDFKit), so an iPad target can
/// reuse it. Nothing here guesses a physical size: an image whose resolution is missing or
/// implausible becomes a sheet marked "no trusted resolution", and the caller keeps the page
/// uncalibrated until the person calibrates it.
let package = Package(
    name: "ZPDFImageIntake",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFImageIntake", targets: ["ZPDFImageIntake"])
    ],
    targets: [
        .target(
            name: "ZPDFImageIntake",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFImageIntakeTests",
            dependencies: ["ZPDFImageIntake"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
