import AppKit
import Foundation
import ZPDFContracts
import ZPDFDXF
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFUIPresentation

/// Opening a CAD drawing (NL-PLAT-05).
///
/// A DXF — the openly documented exchange format — becomes a vector PDF sheet at a standard
/// scale, one layer per DXF layer, written into the app's container beside a copy of the original.
/// When the file states its unit (`$INSUNITS`), the page is given that exact scale at once, labelled
/// as coming from the drawing file, so a 12 000 mm wall measures 12.000 m with no calibration. A
/// DWG is a closed format: it gets a sentence naming the way forward, never "cannot open".
///
/// The DXF is parsed and drawn in `GeometryService.xpc` (round 2) by the bounded pure-Swift reader
/// (no C code; size, entity and nesting caps; fuzzed with 10 000 mutated files): the app sends the
/// file as a read-only descriptor and receives the finished sheet. Only a build with no service
/// bundle — `swift run`, `swift test` — runs the same code in process, exactly as vector extraction
/// falls back. The shipping app never parses a DXF in its own process.
enum CADDrawingIntake {

    static let dxfExtension = "dxf"
    static let dwgExtension = "dwg"

    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == dxfExtension || ext == dwgExtension
    }

    struct Derived: Sendable {
        var pdf: URL
        var original: URL
        var sheet: DXFWireSheet
    }

    static var derivedRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Zenit PDF/Drawings from CAD", isDirectory: true)
    }

    /// The DWG answer, as an error an open reports.
    static func dwgError(fileName: String) -> NSError {
        NSError(domain: "com.zenitgroup.zenitpdf.cad-intake", code: 2, userInfo: [
            NSLocalizedDescriptionKey: String(
                format: NSLocalizedString("“%@” is a DWG drawing.", comment: "DWG refusal headline; the file name"), fileName),
            NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(
                "DWG is a closed format Zenit PDF cannot read. Ask for a PDF or DXF export, or save it as DXF in your CAD program, then open that.",
                comment: "DWG refusal: how to get a readable file"),
        ])
    }

    static func openError(_ error: Error, fileName: String) -> NSError {
        NSError(domain: "com.zenitgroup.zenitpdf.cad-intake", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(
                format: NSLocalizedString("Zenit PDF cannot open “%@” as a drawing.", comment: "Image intake refusal headline; the file name"), fileName),
            NSLocalizedRecoverySuggestionErrorKey: refusalText(error),
        ])
    }

    /// The reader's own words when the service refused the file; otherwise the error's.
    static func refusalText(_ error: Error) -> String {
        if let refusal = error as? DXFError { return refusal.description }
        if case let ZPDFServiceError.remoteFailure(domain, _, message) = error, domain == "ZPDFDXF" { return message }
        return (error as? CustomStringConvertible)?.description ?? error.localizedDescription
    }

    /// Converts one DXF in the geometry service and writes the sheet into a new folder under
    /// `root`. The app never parses the file.
    static func derive(from dxf: URL, into root: URL) async throws -> Derived {
        let baseName = dxf.deletingPathExtension().lastPathComponent
        let sheet = try await GeometryExtraction.client.convertDXF(documentAt: dxf, title: baseName)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let pdf = folder.appendingPathComponent("\(baseName).pdf")
            try sheet.pdf.write(to: pdf, options: .atomic)
            let original = folder.appendingPathComponent(dxf.lastPathComponent)
            try FileManager.default.copyItem(at: dxf, to: original)
            return Derived(pdf: pdf, original: original, sheet: sheet)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The scale label: the ratio and where it came from.
    static func scaleLabel(for sheet: DXFWireSheet) -> String {
        String(
            format: NSLocalizedString("1:%1$lld from the drawing file (%2$@)", comment: "Scale label for a DXF sheet; denominator, the file's unit name"),
            Int64(sheet.scaleDenominator), sheet.unit.name
        )
    }

    static let noteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A30")!

    static func openedNote(for sheet: DXFWireSheet, fileName: String) -> AppWarning {
        let skipped = sheet.skipped.values.reduce(0, +)
        var message = sheet.scaleIsFromFile
            ? String(format: NSLocalizedString("Drawn at 1:%lld from the file's own units. Measure straight away; no calibration needed.", comment: "DXF opened note detail; denominator"), Int64(sheet.scaleDenominator))
            : NSLocalizedString("The file states no unit, so it is drawn as if one unit were a millimetre and is not to scale. Calibrate before measuring.", comment: "DXF opened note detail for a unitless file")
        if skipped > 0 {
            message += " " + String(format: NSLocalizedString("%lld entities of kinds Zenit PDF does not draw (such as hatch fills) were left out.", comment: "DXF opened note: skipped entities"), Int64(skipped))
        }
        return AppWarning(
            id: noteID,
            severity: sheet.scaleIsFromFile && skipped == 0 ? .info : .warning,
            title: String(format: NSLocalizedString("Opened “%1$@” with %2$lld layers", comment: "DXF opened note title; file name, layer count"), fileName, Int64(sheet.layers.count)),
            message: message,
            source: NSLocalizedString("CAD", comment: "Status note source for drawings made from CAD files"),
            isDismissible: true,
            timestamp: Date()
        )
    }

    /// Once the document's presenters exist: installs the file's scale on its page (one undoable
    /// step) and posts the note.
    @MainActor
    static func finishOpening(_ document: ZenitPDFProjectDocument, derived: Derived, fileName: String) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while document.core == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            guard let core = document.core else { return }
            if derived.sheet.scaleIsFromFile, let page = await core.session.firstPageID {
                _ = try? await core.commands.setPresetScale(
                    page: page, ratioDenominator: Decimal(derived.sheet.scaleDenominator), label: scaleLabel(for: derived.sheet))
                await core.refresh()
            }
            core.document.post(openedNote(for: derived.sheet, fileName: fileName))
        }
    }
}

extension ZenitDocumentController {

    /// Opens a DXF as a drawing, or answers a DWG with a sentence (NL-PLAT-05).
    func openCADDrawing(
        _ url: URL,
        release: (() -> Void)?,
        display displayDocument: Bool,
        root: URL = CADDrawingIntake.derivedRoot,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        guard url.pathExtension.lowercased() == CADDrawingIntake.dxfExtension else {
            release?()
            completionHandler(nil, false, CADDrawingIntake.dwgError(fileName: url.lastPathComponent))
            return
        }
        Task { @MainActor in
            let outcome: Result<CADDrawingIntake.Derived, any Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await CADDrawingIntake.derive(from: url, into: root)) } catch { return .failure(error) }
            }.value
            release?()
            switch outcome {
            case let .failure(error):
                completionHandler(nil, false, CADDrawingIntake.openError(error, fileName: url.lastPathComponent))
            case let .success(derived):
                self.openDerivedDrawing(derived.pdf, display: displayDocument) { document, alreadyOpen, error in
                    if let document = document as? ZenitPDFProjectDocument {
                        CADDrawingIntake.finishOpening(document, derived: derived, fileName: url.lastPathComponent)
                    }
                    completionHandler(document, alreadyOpen, error)
                }
            }
        }
    }
}

extension DXFWireSheet {
    /// The file's unit, as the reader names it.
    var unit: DXFUnit { DXFUnit(rawValue: unitRawValue) ?? .unitless }
}
