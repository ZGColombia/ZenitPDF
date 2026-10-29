// swift-tools-version:6.0
import PackageDescription

/// `ZPDFSpreadsheet` reads a spreadsheet back (NL-PLAT-07): the `.xlsx` zip container and the
/// SpreadsheetML inside it, as a grid of cell texts.
///
/// No dependency: the zip central directory is parsed here, entries are inflated with Apple's
/// `Compression` framework, and XML is read with `XMLParser` (external entities off). Every file
/// is untrusted: entry count, sizes and inflation ratio are capped *before* anything is inflated,
/// and inflation stops the moment output passes the declared size, so a zip bomb is refused rather
/// than expanded. Portable (macOS and iOS).
let package = Package(
    name: "ZPDFSpreadsheet",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFSpreadsheet", targets: ["ZPDFSpreadsheet"])
    ],
    targets: [
        .target(name: "ZPDFSpreadsheet", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ZPDFSpreadsheetTests", dependencies: ["ZPDFSpreadsheet"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
