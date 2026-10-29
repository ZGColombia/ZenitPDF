// swift-tools-version:6.0
import PackageDescription

/// `ZPDFUIPresentation` is the UI-side presentation / adapter layer of Zenit PDF.
///
/// It owns the `Sendable` value types that every UI package renders, the
/// `@MainActor` presenter protocols that those packages observe, and in-memory
/// mock presenters so the UI can be built and previewed without the core engines
/// (measurement, snap, ledger, GRDB, PDFium). The mocks compile
/// only under `DEBUG || ZPDF_MOCKS` (R-142): a release build ships none of them.
///
/// The package deliberately has zero dependencies: it is the seam that the
/// frozen domain contracts are bound to.
let package = Package(
    name: "ZPDFUIPresentation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFUIPresentation", targets: ["ZPDFUIPresentation"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ZPDFUIPresentation",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFUIPresentationTests",
            dependencies: ["ZPDFUIPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
