// swift-tools-version:6.0
import PackageDescription

/// The Zenit PDF application target.
///
/// The product is an AppKit document application, not a SwiftUI `App`: the document model is
/// `NSDocument` and the window is an `NSSplitViewController` composition owned by
/// `ZPDFUIShell`. `SwiftUI` appears only inside `NSHostingView`, which is where the design system
/// lives.
///
/// The split between `ZenitPDFAppKit` and `ZenitPDF` is deliberate. All behaviour lives in the
/// library so it can be unit tested; the executable is `main.swift` and nothing else. A test
/// target cannot link an executable's `main` symbol without trouble, and the app's menu table,
/// document-mode routing and page geometry are exactly the parts that need tests.
let package = Package(
    name: "ZenitPDFApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZenitPDF", targets: ["ZenitPDF"]),
        .library(name: "ZenitPDFAppKit", targets: ["ZenitPDFAppKit"])
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFAppCore"),
        .package(path: "../../Packages/ZPDFContracts"),
        .package(path: "../../Packages/ZPDFGeometry"),
        .package(path: "../../Packages/ZPDFMeasurementEngine"),
        .package(path: "../../Packages/ZPDFPDFKitBridge"),
        .package(path: "../../Packages/ZPDFPersistence"),
        .package(path: "../../Packages/ZPDFRenderer"),
        .package(path: "../../Packages/ZPDFSnapEngine"),
        .package(path: "../../Packages/ZPDFVectorExtraction"),
        .package(path: "../../Packages/ZPDFServiceClient"),
        .package(path: "../../Packages/ZPDFUIPresentation"),
        .package(path: "../../Packages/ZPDFDesignSystem"),
        .package(path: "../../Packages/ZPDFUIShell"),
        .package(path: "../../Packages/ZPDFUILedger"),
        .package(path: "../../Packages/ZPDFUIMeasurement"),
        .package(path: "../../Packages/ZPDFUIWorkflows"),
        .package(path: "../../Packages/ZPDFExport"),
        .package(path: "../../Packages/ZPDFQuantityLedger"),
        .package(path: "../../Packages/ZPDFTestingSupport"),
        .package(path: "../../Packages/ZPDFImageIntake"),
        .package(path: "../../Packages/ZPDFSpreadsheet"),
        .package(path: "../../Packages/ZPDFDXF"),
        .package(path: "../../Packages/ZPDFMeasureDictionary"),
        .package(path: "../../Packages/ZPDFExtensions"),
        .package(path: "../../Packages/ZPDFRasterAnalysis"),
        .package(path: "../../Packages/ZPDFCanvasCore"),   // NL-PLAT-17: the canvas's portable half
        .package(path: "../../Packages/ZPDFSearch"),
        // NL-PLAT-21: the Quick Look preview's summary format, written by the app after a save.
        .package(path: "../QuickLookThumbnail")
    ],
    targets: [
        .target(
            name: "ZenitPDFAppKit",
            dependencies: [
                .product(name: "ZPDFAppCore", package: "ZPDFAppCore"),
                .product(name: "ZPDFContracts", package: "ZPDFContracts"),
                .product(name: "ZPDFGeometry", package: "ZPDFGeometry"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                // The markup renderer, for the vector underlay: the page's
                // own extracted linework drawn under the raster while the raster is in flight.
                .product(name: "ZPDFRenderer", package: "ZPDFRenderer"),
                .product(name: "ZPDFSnapEngine", package: "ZPDFSnapEngine"),
                // The coverage map: the canvas computes covered/uncovered regions for the overlay.
                .product(name: "ZPDFMeasurementEngine", package: "ZPDFMeasurementEngine"),
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction"),
                .product(name: "ZPDFServiceClient", package: "ZPDFServiceClient"),
                .product(name: "ZPDFServiceWire", package: "ZPDFServiceClient"),
                .product(name: "ZPDFUIPresentation", package: "ZPDFUIPresentation"),
                .product(name: "ZPDFDesignSystem", package: "ZPDFDesignSystem"),
                .product(name: "ZPDFUIShell", package: "ZPDFUIShell"),
                .product(name: "ZPDFUILedger", package: "ZPDFUILedger"),
                .product(name: "ZPDFUIMeasurement", package: "ZPDFUIMeasurement"),
                .product(name: "ZPDFUIWorkflows", package: "ZPDFUIWorkflows"),
                .product(name: "ZPDFExport", package: "ZPDFExport"),
                .product(name: "ZPDFQuantityLedger", package: "ZPDFQuantityLedger"),
                // Scans and photos of sheets become PDF drawings at a recorded resolution
                // (NL-PLAT-04).
                .product(name: "ZPDFImageIntake", package: "ZPDFImageIntake"),
                // Reading an exported workbook back, for the reviewed apply (NL-PLAT-07).
                .product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet"),
                // DXF drawings as scaled vector sheets (NL-PLAT-05).
                .product(name: "ZPDFDXF", package: "ZPDFDXF"),
                // The scale CAD programs write into PDFs (NL-PLAT-06).
                .product(name: "ZPDFMeasureDictionary", package: "ZPDFMeasureDictionary"),
                // Declarative packs of tool sets, templates and export profiles (NL-PLAT-23).
                .product(name: "ZPDFExtensions", package: "ZPDFExtensions"),
                // Automation on scanned sheets: linework and symbols read from pixels (NL-AUTO-14).
                .product(name: "ZPDFRasterAnalysis", package: "ZPDFRasterAnalysis"),
                .product(name: "ZPDFCanvasCore", package: "ZPDFCanvasCore"),
                // On-device recognition of files that are not open, for the batch processor's
                // Make Searchable step (NL-PDF-19).
                .product(name: "ZPDFSearch", package: "ZPDFSearch"),
                // The Space-bar preview's summary (NL-PLAT-21): one Codable type, which the app
                // writes and the Quick Look preview extension reads.
                .product(name: "ZenitQuickLookCore", package: "QuickLookThumbnail")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ZenitPDF",
            dependencies: ["ZenitPDFAppKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZenitPDFAppKitTests",
            dependencies: [
                "ZenitPDFAppKit",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport"),
                // The repair worker, so the repair flow can be driven out of process from
                // `swift test`. A test process is not an application bundle, so
                // `NSXPCConnection(serviceName:)` cannot find `RepairService.xpc` and the
                // flow's regression test could not run at all; this executable is the same
                // service handler the `.xpc` wraps, reached through
                // `ZPDFRepairServiceClient.Backend.subprocess`.
                //
                // Deliberately *not* `ZPDFRepairServiceCore`: that target carries qpdf, and
                // linking it would put the vendored C++ parser inside the process the
                // service exists to keep it out of (S17-03) — measurably so, in fact.
                // Running it in-process corrupted unrelated SQLite work in parallel suites
                // (`SQLite error 10: disk I/O error`, and a crash marker left armed) and
                // those failures vanish when the same repair runs in a child process, which
                // is the isolation argument stated as a measurement.
                .product(name: "zpdf-repair-worker", package: "ZPDFServiceClient")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
