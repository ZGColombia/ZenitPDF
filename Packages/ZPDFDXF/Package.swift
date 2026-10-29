// swift-tools-version:6.0
import PackageDescription

/// `ZPDFDXF` reads DXF — the openly documented CAD exchange format — and writes it as a vector
/// PDF sheet at an exact, stated scale, one optional-content layer per DXF layer (NL-PLAT-05).
///
/// Pure Swift, no dependency, portable. Every file is untrusted: binary DXF, oversized files,
/// too many entities and runaway block nesting are refused with a reason, and the parser never
/// indexes past what it has read. DWG is a closed format and is not read at all.
let package = Package(
    name: "ZPDFDXF",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFDXF", targets: ["ZPDFDXF"])
    ],
    targets: [
        .target(name: "ZPDFDXF", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ZPDFDXFTests", dependencies: ["ZPDFDXF"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
