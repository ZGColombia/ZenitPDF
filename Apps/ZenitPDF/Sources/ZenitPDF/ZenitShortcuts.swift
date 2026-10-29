import AppIntents
import Foundation
import ZenitPDFAppKit

// Shortcuts actions (NL-PLAT-12). Kept in the executable module on purpose: Scripts/build-app.sh
// extracts `Metadata.appintents` from this module's constant values with
// `appintentsmetadataprocessor`, because a SwiftPM build does not run Xcode's extraction phase,
// and the build fails if the metadata is missing. Every action is a thin call into
// `ZenitShortcutsBridge`, the same code the menus use. Nothing here needs a network.

enum LedgerExportFormat: String, AppEnum {
    case xlsx, csv, json

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ledger Format"
    static let caseDisplayRepresentations: [LedgerExportFormat: DisplayRepresentation] = [
        .xlsx: "Excel Workbook (.xlsx)",
        .csv: "CSV",
        .json: "Zenit JSON (.zpdfjson)",
    ]
}

struct ExportQuantityLedgerIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Quantity Ledger"
    static let description = IntentDescription("Exports the Quantity Ledger of the drawing or project in front, as it is on screen.")

    @Parameter(title: "Format", default: .xlsx)
    var format: LedgerExportFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Export the Quantity Ledger as \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let bridgeFormat = ZenitShortcutsBridge.LedgerFormat(rawValue: format.rawValue) ?? .xlsx
        let url = try await ZenitShortcutsBridge.exportFrontLedger(format: bridgeFormat)
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent))
    }
}

struct GetLedgerTotalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Totals"
    static let description = IntentDescription("Returns the Quantity Ledger's totals of the drawing or project in front, one line per quantity.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ZenitShortcutsBridge.frontTotals())
    }
}

struct OpenDrawingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Drawing or Project"
    static let description = IntentDescription("Opens a PDF drawing, a scan, a DXF or a Zenit PDF project.")
    static let openAppWhenRun = true

    @Parameter(title: "File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = file.fileURL else { return .result() }
        try await ZenitShortcutsBridge.open(url)
        return .result()
    }
}

struct ZenitShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetLedgerTotalsIntent(),
            phrases: ["Get totals in \(.applicationName)", "Show the ledger totals in \(.applicationName)"],
            shortTitle: "Get Totals",
            systemImageName: "sum"
        )
        AppShortcut(
            intent: ExportQuantityLedgerIntent(),
            phrases: ["Export the quantity ledger in \(.applicationName)"],
            shortTitle: "Export Ledger",
            systemImageName: "tablecells"
        )
    }
}
