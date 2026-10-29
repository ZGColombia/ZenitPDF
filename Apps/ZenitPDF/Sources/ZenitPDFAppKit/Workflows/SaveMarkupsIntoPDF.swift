import AppKit
import Foundation
import ZPDFAppCore
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// File ▸ Save Markups into PDF… (NL-PDF-03, ADR-0023).
///
/// The markups as standard annotations **and** the measurement takeoff as an associated file,
/// appended to the drawing as an incremental update, after a confirmation that says exactly that.
/// In Quick PDF Mode the update goes onto the opened PDF itself; in Project Mode the drawing
/// inside the package is the project's evidence and is never written, so the artefact goes to a
/// file the person chooses.
///
/// The original drawing is the written file's prefix, byte for byte: a signature over it keeps
/// covering it, and a later reader can prove the takeoff belongs to the drawing it sits on.
@MainActor
enum SaveMarkupsIntoPDF {

    static let confirmIdentifier = "pdf.saveIntoConfirm"
    static let panelIdentifier = "pdf.saveIntoPanel"
    static let resultNoteID = UUID(uuidString: "5E2B7C10-4A3F-4D6E-8B91-2C7D0F4A6B35")!

    /// What one save did.
    struct Result: Sendable {
        var outcome: StandardAnnotationOutcome
        var destination: URL
        var wroteInPlace: Bool
        /// In a project of several drawings, the sentence naming the one drawing written and
        /// what stays out (W-017); `nil` for one drawing.
        var leftOut: String? = nil
    }

    // MARK: - The confirmation

    /// The alert a person answers before the drawing changes. Two buttons: Save into PDF, Cancel.
    static func confirmation(fileName: String, annotationCount: Int, inPlace: Bool, signer: String? = nil, leftOut: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(
            format: inPlace
                ? NSLocalizedString("Save markups into “%@”?", comment: "Save into PDF confirmation headline; the file name")
                : NSLocalizedString("Save markups into a copy of “%@”?", comment: "Save into PDF (project) confirmation headline; the file name"),
            fileName
        )
        // Singular for one (L-26: "1 annotations and the takeoff are added …").
        alert.informativeText = LocalizedPlural.string(
            "%lld annotations and the takeoff are added to the end of the file. The original drawing stays unchanged at the start of the file, so any signature on it stays valid, and annotations other people made are kept.",
            count: annotationCount,
            one: NSLocalizedString(
                "%lld annotation and the takeoff are added to the end of the file. The original drawing stays unchanged at the start of the file, so any signature on it stays valid, and annotations other people made are kept.",
                comment: "Save into PDF confirmation detail, one annotation; the count"
            ),
            other: NSLocalizedString(
                "%lld annotations and the takeoff are added to the end of the file. The original drawing stays unchanged at the start of the file, so any signature on it stays valid, and annotations other people made are kept.",
                comment: "Save into PDF confirmation detail, several annotations; the count"
            )
        )
        if let signer {
            alert.informativeText += " " + String(
                format: NSLocalizedString(
                    "The drawing is signed by %@; the signature keeps covering the original drawing.",
                    comment: "Save into PDF confirmation: signed drawing; the signer"
                ),
                signer
            )
        }
        // A project of several drawings: the file is one drawing's, and says so (W-017).
        if let leftOut { alert.informativeText += " " + leftOut }
        alert.addButton(withTitle: NSLocalizedString("Save into PDF", comment: "Save into PDF confirmation: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button: cancel"))
        return alert
    }

    // MARK: - The write

    /// Appends the job's annotations and `overlay` to the drawing at `job.sourceURL` and writes
    /// the result to `destination` atomically — which may be the source itself.
    ///
    /// Refuses when the file on disk does not begin with the bytes the document opened.
    static func write(
        job: StandardAnnotationExport.Job,
        overlay: Data?,
        archive: Data? = nil,
        to destination: URL
    ) throws -> StandardAnnotationOutcome {
        let current = try Data(contentsOf: job.sourceURL, options: .mappedIfSafe)
        guard let opened = job.sourceDigest else {
            throw ExportError.annotationExportRefused(
                "the drawing's identity is not known, so the takeoff could not be tied to it."
            )
        }
        try StandardAnnotationExport.verifyBegins(current, with: opened)
        let takeoff = overlay.map {
            EmbeddedTakeoff(payload: $0, sourceByteCount: opened.byteCount, sourceSHA256: opened.sha256.lowercased())
        }
        // The session archive rides beside the overlay so a reopen can restore the takeoff
        // exactly (NL-PDF-03 restore, `EmbeddedTakeoffRestore.swift`).
        let companions = takeoff == nil ? [] : archive.map {
            [EmbeddedTakeoff(fileName: EmbeddedSessionArchive.fileName, payload: $0,
                             sourceByteCount: opened.byteCount, sourceSHA256: opened.sha256.lowercased())]
        } ?? []
        let produced = try StandardAnnotationWriter().data(source: current, pages: job.pages, takeoff: takeoff, attachments: companions)
        try atomicallyReplace(destination, with: produced.data)
        return produced.outcome
    }

    /// Writes `data` to a sibling temporary and moves it over `destination`. The destination is
    /// never removed first, so a failed write leaves whatever was there.
    static func atomicallyReplace(_ destination: URL, with data: Data) throws {
        let manager = FileManager.default
        let directory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        )
        defer { try? manager.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("zpdf-save-into-\(UUID().uuidString).pdf")
        try data.write(to: temporary)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    /// The note posted afterwards.
    static func resultNote(for result: Result, now: Date = Date()) -> AppWarning {
        // Singular for one (L-26: "1 annotations, one per markup").
        var parts: [String] = [LocalizedPlural.string(
            "%lld annotations, one per markup. The original drawing is unchanged at the start of the file.",
            count: result.outcome.writtenAnnotationCount,
            one: NSLocalizedString(
                "%lld annotation, for the one markup. The original drawing is unchanged at the start of the file.",
                comment: "Save into PDF note, one annotation; the count"
            ),
            other: NSLocalizedString(
                "%lld annotations, one per markup. The original drawing is unchanged at the start of the file.",
                comment: "Save into PDF note, several annotations; the count"
            )
        )]
        if result.outcome.takeoffEmbedded {
            parts.append(NSLocalizedString(
                "The measurements travel inside the file as a takeoff Zenit can read back.",
                comment: "Save into PDF note: takeoff embedded"
            ))
        } else if let note = result.outcome.takeoffNote {
            parts.append(note)
        }
        if let leftOut = result.leftOut { parts.append(leftOut) }
        if result.outcome.supersededAnnotationCount > 0 {
            parts.append(NSLocalizedString(
                "Annotations from an earlier save were replaced, not duplicated.",
                comment: "Save into PDF note: superseded"
            ))
        }
        return AppWarning(
            id: resultNoteID,
            severity: result.outcome.rejectedMarkupCount > 0 ? .warning : .info,
            title: String(
                format: NSLocalizedString("Markups saved into “%@”", comment: "Save into PDF headline; the file name"),
                result.destination.lastPathComponent
            ),
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }
}

extension ProjectWindowController {

    /// File ▸ Save Markups into PDF….
    func saveMarkupsIntoPDF(for document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing else { return }
        Task { @MainActor in
            do {
                let job = try await StandardAnnotationExport.job(
                    for: document,
                    artwork: { [weak document] digest in
                        guard let package = document?.projectPackage else { return nil }
                        return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
                    },
                    // NL-COLLAB-07: each markup's replies travel as /IRT replies (nl-collaboration).
                    replies: document.reviewRepliesForExport()
                )
                let inPlace = document.mode == .quickPDF
                let alert = SaveMarkupsIntoPDF.confirmation(
                    fileName: drawing.url.lastPathComponent,
                    annotationCount: job.annotationCount,
                    inPlace: inPlace,
                    signer: SignatureInspector.signatures(ofFileAt: drawing.url).first.map {
                        $0.signer ?? NSLocalizedString("an unreadable certificate", comment: "Signer name when the certificate cannot be read")
                    },
                    leftOut: document.primaryDrawingOnlySentence()
                )
                ZenitModalPresenter.runAlert(
                    alert,
                    identifier: SaveMarkupsIntoPDF.confirmIdentifier,
                    sheetedOn: window,
                    answerWithoutAUser: .button(1)
                ) { answer in
                    guard answer.buttonIndex == 0 else { return }
                    if inPlace {
                        self.performSaveIntoPDF(job: job, document: document, destination: drawing.url, inPlace: true)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent
                        + " — " + NSLocalizedString("With Markups", comment: "Save into PDF copy file-name suffix") + ".pdf"
                    panel.message = NSLocalizedString(
                        "The drawing in this project is never changed. Choose where the PDF with the markups goes.",
                        comment: "Save into PDF (project) panel message"
                    )
                    ZenitModalPresenter.runSavePanel(panel, identifier: SaveMarkupsIntoPDF.panelIdentifier, sheetedOn: self.window) { chosen in
                        guard let url = chosen.firstURL else { return }
                        self.performSaveIntoPDF(job: job, document: document, destination: url, inPlace: false)
                    }
                }
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// The half of the command after the answers: builds the overlay, writes, reports.
    func performSaveIntoPDF(
        job: StandardAnnotationExport.Job,
        document: ZenitPDFProjectDocument,
        destination: URL,
        inPlace: Bool
    ) {
        Task { @MainActor in
            do {
                let result = try await saveIntoPDF(job: job, document: document, destination: destination, inPlace: inPlace)
                document.core?.document.post(SaveMarkupsIntoPDF.resultNote(for: result))
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// The write, awaited: what a test drives after answering the confirmation.
    func saveIntoPDF(
        job: StandardAnnotationExport.Job,
        document: ZenitPDFProjectDocument,
        destination: URL,
        inPlace: Bool
    ) async throws -> SaveMarkupsIntoPDF.Result {
        if !inPlace, let package = document.projectPackage?.url,
           destination.standardizedFileURL.path.hasPrefix(package.standardizedFileURL.path) {
            throw ExportError.annotationExportRefused(
                "the project package holds the drawing as evidence and is never written by this command."
            )
        }
        let overlay = try await MeasurementOverlayTransfer.overlayData(for: document)
        var archive: Data?
        if let core = document.core, let drawing = document.drawing {
            // The drawing's own pages in file order, the order of the bytes written (W-017).
            archive = try EmbeddedSessionArchive.encode(
                await core.session.takeoffState(), pages: drawing.pages, documentID: drawing.documentID
            )
        }
        let outcome = try SaveMarkupsIntoPDF.write(job: job, overlay: overlay, archive: archive, to: destination)
        if inPlace {
            // The canvas keeps drawing the file as it opened, without these; outputs leave them
            // out too, even once their markup is deleted (L-23).
            ZenitAnnotationSupersession.record(job.pages.flatMap { $0.annotations.map(\.name) }, for: document)
        }
        ExportCompletion.remember(destination, document: document)
        return SaveMarkupsIntoPDF.Result(
            outcome: outcome, destination: destination, wroteInPlace: inPlace,
            leftOut: document.primaryDrawingOnlySentence()
        )
    }
}
