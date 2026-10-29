// swift-tools-version:6.0
import PackageDescription

/// `ZPDFPDFKitBridge` is everything Zenit PDF needs from PDFKit, behind one protocol.
///
/// Nothing above this package imports PDFKit. Call sites talk to ``PDFDocumentProviding``
/// and exchange `Sendable` value types, so the PDFKit-backed implementation can be
/// replaced by a PDFium- or qpdf-backed one — or by a fake in a test — without a single
/// call-site edit.
///
/// The library target has no dependencies at all: not `ZPDFContracts`, not `ZPDFGeometry`,
/// and no UI package. A later integration pass binds the neutral types defined here to the
/// frozen contracts. The fixture corpus is a dependency of the *test* target only.
let package = Package(
    name: "ZPDFPDFKitBridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFPDFKitBridge", targets: ["ZPDFPDFKitBridge"])
    ],
    dependencies: [
        // ADR-0011: artwork import produces a frozen-contract value, and compiles a PDF page
        // through the `CGPDFScanner` path this repository already owns for Vector Snap. Two
        // scanners would disagree and a mirrored geometry vocabulary would drift, so the
        // package's original "no dependencies at all" is spent here, deliberately, on two
        // dependency-light local packages.
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFVectorExtraction"),
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        // Objective-C only, and deliberately tiny: `@try`/`@catch` is not expressible
        // in Swift, and PDFKit raises `NSException` on malformed input. Without this
        // barrier a hostile `/Info` dictionary terminates the process.
        .target(
            name: "ZPDFEngineBarrier"
        ),
        .target(
            name: "ZPDFPDFKitBridge",
            dependencies: [
                "ZPDFEngineBarrier",
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFPDFKitBridgeTests",
            dependencies: [
                "ZPDFPDFKitBridge",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
