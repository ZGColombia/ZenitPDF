// swift-tools-version:6.0
import PackageDescription

/// `GoldenMeasurements` is the acceptance gate for the measurement engine (spec 1.2, 12).
///
/// It is a corpus of hand-derived and independently derived measurement cases: geometry, a
/// scale, parameters, and the numbers a competent estimator with a calculator would write down.
/// **No expected value in this package is produced by the code under test.** Each case records
/// how its expectation was obtained, and the test target additionally cross-checks a subset of
/// the areas with a Monte-Carlo estimate that shares no code with the engine.
///
/// Tolerances are the ones spec 1.2 names: 0.05 % for lengths, 0.10 % for areas, 0.15 % for
/// volumes, exact for counts.
let package = Package(
    name: "GoldenMeasurements",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GoldenMeasurements", targets: ["GoldenMeasurements"])
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFContracts"),
        .package(path: "../../Packages/ZPDFMeasurementEngine")
    ],
    targets: [
        .target(
            name: "GoldenMeasurements",
            dependencies: [
                .product(name: "ZPDFContracts", package: "ZPDFContracts")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GoldenMeasurementsTests",
            dependencies: [
                "GoldenMeasurements",
                .product(name: "ZPDFMeasurementEngine", package: "ZPDFMeasurementEngine")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
