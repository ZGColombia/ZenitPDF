// swift-tools-version:6.0
import PackageDescription

/// `ZPDFUIMeasurement` is the measurement experience of Zenit PDF: calibration, Scale Regions,
/// bulk scale application, per-tool options, the live on-canvas caption, Vector Snap feedback,
/// the precision loupe and the full keyboard drawing flow.
///
/// The package renders `ZPDFUIPresentation` value types with `ZPDFDesignSystem` components and
/// never talks to PDFium, SQLite or the measurement engine directly. The one piece of logic it
/// owns is input and input validation: `MeasurementInputStateMachine` and `CalibrationValidator`
/// are pure value types with no view dependency, so both are unit tested here.
let package = Package(
    name: "ZPDFUIMeasurement",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFUIMeasurement", targets: ["ZPDFUIMeasurement"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFDesignSystem")
    ],
    targets: [
        .target(
            name: "ZPDFUIMeasurement",
            dependencies: ["ZPDFUIPresentation", "ZPDFDesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFUIMeasurementTests",
            dependencies: ["ZPDFUIMeasurement", "ZPDFUIPresentation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
