// swift-tools-version:6.0
import PackageDescription

/// `ZPDFExport` is every export path out of the Quantity Ledger (spec 15.8) — CSV, the Zenit
/// JSON interchange, the paginated PDF report and XLSX — plus nothing else.
///
/// # The one rule this package exists to enforce
///
/// `ZPDFQuantityLedger` already produces `LedgerReport`, an export-ready projection whose values
/// are exact `Decimal`s carrying the formatting metadata needed to present them. That projection
/// is the **only** input any exporter here is allowed to see. Exactly one type reads it —
/// ``ExportProjector`` — and it turns it into an ``ExportProjection`` in which every value has
/// already been converted, rounded once and rendered to its final string. The four exporters
/// take an `ExportProjection` and cannot take anything else, so "the CSV re-rounded" and "the
/// PDF re-grouped" are not bugs that have to be tested for; they are states the type system
/// does not have (QUALITY_BAR A25, A29, A30, A34).
let package = Package(
    name: "ZPDFExport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFExport", targets: ["ZPDFExport"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts"),
        .package(path: "../ZPDFQuantityLedger"),
        .package(path: "../ZPDFFormulaEngine"),
        .package(path: "../ZPDFRenderer"),
        .package(path: "../ZPDFPDFKitBridge"),
        .package(path: "../../Bridges/LibXlsxWriterBridge"),
        // Test only: the annotated export's /Measure and /VP must read back through the same
        // reader the app uses for a CAD drawing's scale (NL-PLAT-06 write half).
        .package(path: "../ZPDFMeasureDictionary")
    ],
    targets: [
        .target(
            name: "ZPDFExport",
            dependencies: [
                "ZPDFContracts",
                "ZPDFQuantityLedger",
                // NL-QTY-13: a formula column is written into the workbook as a cell formula,
                // translated from the one engine's own syntax tree — never re-parsed by hand.
                "ZPDFFormulaEngine",
                // ADR-0006: the snippet compositor is the renderer's offscreen path plus the
                // PDFKit bridge's page raster, captioned from the same LedgerReport projection
                // every other exporter reads. It lives here, with the exporters, because the
                // caption must share their formatting metadata.
                "ZPDFRenderer",
                "ZPDFPDFKitBridge",
                .product(name: "ZPDFXlsxWriter", package: "LibXlsxWriterBridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Test only: Apply Redactions' file writes run in a child process under `sandbox-exec`,
        // with the grant a save panel or a folder chooser gives the sandboxed app, because
        // `swift test` itself runs unsandboxed and cannot see a refused write (C-09: a save
        // panel grants the chosen file and nothing beside it). Never bundled into the app.
        .executableTarget(
            name: "zpdf-redaction-probe",
            dependencies: ["ZPDFExport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFExportTests",
            dependencies: [
                "ZPDFExport", "ZPDFContracts", "ZPDFQuantityLedger", "ZPDFFormulaEngine",
                .product(name: "ZPDFMeasureDictionary", package: "ZPDFMeasureDictionary"),
                "zpdf-redaction-probe"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
