import AppKit
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// AppleScript (NL-PLAT-11): the dictionary in `Bundle/ZenitPDF.sdef`, served here.
///
/// ```applescript
/// tell application "Zenit PDF"
///     get {name, page count, scale state} of document 1
///     get quantity of every ledger row of document 1
///     get totals document 1
///     export ledger document 1 to POSIX file "/Users/me/Desktop/Ledger.xlsx" as xlsx
///     apply template document 1 named "Flooring"
/// end tell
/// ```
///
/// Every command calls the code its menu command runs: the ledger export through the writer the
/// Shortcuts action and File ▸ Export… share, the totals as Get Totals answers, the template through
/// ``NewFromTemplate/apply(_:to:)``. Ledger rows are read-only — a quantity comes from geometry,
/// never from a script. Commands that need the takeoff's actor suspend the Apple event and
/// resume it with the answer.
@objc(ZenitScriptLedgerRow)
final class ZenitScriptLedgerRow: NSObject {
    @objc let uniqueID: String
    @objc let subject: String
    @objc let label: String
    @objc let quantity: String
    @objc let unit: String
    private weak var container: ZenitPDFProjectDocument?

    init(summary: MarkupSummary, container: ZenitPDFProjectDocument) {
        uniqueID = summary.id.uuidString
        subject = summary.subject
        label = summary.label
        quantity = summary.primaryField?.displayText ?? ""
        unit = summary.primaryField?.displayUnitSymbol ?? ""
        self.container = container
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container else { return nil }
        let containerSpecifier = container.objectSpecifier
        guard let description = containerSpecifier.keyClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: containerSpecifier,
                                   key: "scriptLedgerRows", uniqueID: uniqueID)
    }
}

/// The scripting behaviour as plain async functions, so a test drives exactly what an Apple event
/// runs without a scripting runtime.
@MainActor
enum ZenitScripting {

    enum ScriptError: Error, CustomStringConvertible {
        case noTakeoff
        case unknownTemplate(String)
        case exportFailed(String)
        var description: String {
            switch self {
            case .noTakeoff: return NSLocalizedString("The document has not finished opening.", comment: "AppleScript error: no takeoff yet")
            case let .unknownTemplate(name): return String(format: NSLocalizedString("There is no job template named “%@”.", comment: "AppleScript error: unknown template"), name)
            case let .exportFailed(reason): return String(format: NSLocalizedString("The ledger could not be exported: %@", comment: "AppleScript error: export failed"), reason)
            }
        }
    }

    /// The ledger's grand totals, one line each: the text Shortcuts' Get Totals answers with.
    static func totals(document: ZenitPDFProjectDocument) async throws -> String {
        guard document.core != nil else { throw ScriptError.noTakeoff }
        return try await ZenitShortcutsBridge.totals(of: document)
    }

    /// The dictionary's `ledger format`: the Shortcuts action's formats, one list for both.
    typealias Format = ZenitShortcutsBridge.LedgerFormat

    /// Writes the ledger in `format` to `url`, through the one writer Shortcuts and the menu
    /// share: the on-screen CSV, and a workbook with row identity (R-027).
    static func export(document: ZenitPDFProjectDocument, to url: URL, format: Format) async throws -> URL {
        guard document.core != nil else { throw ScriptError.noTakeoff }
        do {
            try await ZenitShortcutsBridge.writeLedger(of: document, format: format, to: url)
            return url
        } catch {
            throw ScriptError.exportFailed((error as? CustomStringConvertible)?.description ?? error.localizedDescription)
        }
    }

    /// Applies the named template — the person's own first, then the shipped starters.
    static func applyTemplate(named name: String, document: ZenitPDFProjectDocument) async throws -> String {
        guard document.core != nil else { throw ScriptError.noTakeoff }
        guard let template = await NewFromTemplate.templates().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ScriptError.unknownTemplate(name)
        }
        // The one application every door shares, with the open-takeoff note the menu gives
        // (T-010): New from Template's new-takeoff wording told a calibrated project its scale
        // was not set, and its copy of the steps left a saved project clean.
        guard let applied = await document.applyJobTemplate(template) else { throw ScriptError.noTakeoff }
        document.core?.status.setActiveToolNote(ProjectWindowController.jobTemplateAppliedNote(template, applied))
        return String(format: NSLocalizedString("Applied “%1$@”: %2$d tools.", comment: "AppleScript result of apply template"),
                      template.name, applied.receipt.appliedPresetCount)
    }

    /// The four-character codes of the `ledger format` enumeration, as in the dictionary.
    static func format(fromCode code: FourCharCode?) -> Format {
        switch code {
        case fourCharCode("ZNfc"): return .csv
        case fourCharCode("ZNfj"): return .json
        default: return .xlsx
        }
    }

    static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

extension ZenitPDFProjectDocument {

    /// "How many sheets the drawing has" (the dictionary): the set's sheets, as the tab strip
    /// counts them (U-026) — every drawing of a project, without the sheets removed from the set.
    /// The primary PDF's page count was answered.
    @objc var scriptPageCount: Int { core?.snapshot.pages.count ?? drawing?.pages.count ?? 0 }

    @objc var scriptScaleState: String {
        core?.snapshot.documentScaleDescription ?? NSLocalizedString("not calibrated", comment: "AppleScript scale state of an uncalibrated drawing")
    }

    @objc var scriptIsProject: Bool { projectPackage != nil }

    @objc var scriptLedgerRows: [ZenitScriptLedgerRow] {
        (core?.snapshot.markups ?? []).filter { $0.kind == .measurement }.map { ZenitScriptLedgerRow(summary: $0, container: self) }
    }

    /// Runs `work` with the Apple event suspended, and resumes it with the answer or the error.
    private func runSuspended(_ command: NSScriptCommand, _ work: @escaping @MainActor () async throws -> Any?) -> Any? {
        command.suspendExecution()
        Task { @MainActor in
            do {
                let result = try await work()
                command.resumeExecution(withResult: result)
            } catch {
                command.scriptErrorNumber = errOSAGeneralError
                command.scriptErrorString = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    @objc func scriptGetTotals(_ command: NSScriptCommand) -> Any? {
        runSuspended(command) { try await ZenitScripting.totals(document: self) }
    }

    @objc func scriptExportLedger(_ command: NSScriptCommand) -> Any? {
        guard let url = command.evaluatedArguments?["file"] as? URL else {
            command.scriptErrorNumber = errOSAGeneralError
            command.scriptErrorString = NSLocalizedString("Say where to write the ledger: export ledger document 1 to POSIX file \"…\".", comment: "AppleScript error: no destination")
            return nil
        }
        let code = (command.evaluatedArguments?["format"] as? NSNumber).map { FourCharCode(truncating: $0) }
        let format = ZenitScripting.format(fromCode: code)
        return runSuspended(command) { try await ZenitScripting.export(document: self, to: url, format: format).path }
    }

    @objc func scriptApplyTemplate(_ command: NSScriptCommand) -> Any? {
        guard let name = command.evaluatedArguments?["name"] as? String, !name.isEmpty else {
            command.scriptErrorNumber = errOSAGeneralError
            command.scriptErrorString = NSLocalizedString("Name the template: apply template document 1 named \"…\".", comment: "AppleScript error: no template name")
            return nil
        }
        return runSuspended(command) { try await ZenitScripting.applyTemplate(named: name, document: self) }
    }
}
