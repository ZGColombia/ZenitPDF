import Foundation
import ZPDFCompare
import ZPDFPDFKitBridge

/// The one refusal every "write a copy of the drawing" flow shares: the copy may never replace
/// the drawing it is made from.
///
/// Redaction, Scan Clean-up and Fill Form Fields handed the save panel's answer straight to a
/// writer that ends in `replaceItemAt` or an atomic write, and none of them compared it with the
/// drawing; choosing the original in the panel replaced the only unredacted or unfilled drawing
/// with its derived copy (R-026). Optimize Copy and Save Searchable Copy each had a check of
/// their own. Every such flow in the application now asks here, before any work starts; "the
/// same file" is decided by the one comparison the writers themselves use,
/// `StagedFileReplacement.sameItem`.
enum DerivedCopyGuard {

    /// Why a copy was not written.
    struct Refusal: LocalizedError, Equatable {
        /// The drawing's file name.
        let drawingName: String

        var errorDescription: String? {
            String(
                format: NSLocalizedString(
                    "The copy was not written: “%@” is the drawing it is made from.",
                    comment: "Derived copy refusal: the chosen destination is the source drawing; the file name"
                ),
                drawingName
            )
        }

        var recoverySuggestion: String? {
            NSLocalizedString(
                "Choose another name or folder. The drawing is left exactly as it was.",
                comment: "Derived copy refusal: what to do"
            )
        }
    }

    /// A refusal in words with what to do, for a tray note; any other error as it describes
    /// itself.
    static func message(for error: any Error) -> String {
        guard let refusal = error as? Refusal else { return String(describing: error) }
        return [refusal.errorDescription, refusal.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    /// Throws ``Refusal`` when `output` is `source` — the same file however it is spelled:
    /// by resolved path, or by file identity when both exist.
    static func refuseIfSource(_ output: URL, source: URL) throws {
        try StagedFileReplacement.refuseOverwriting(
            [source], with: output, refusal: Refusal(drawingName: source.lastPathComponent)
        )
    }

    /// Throws ``Refusal`` when `output` is any file the document is made of
    /// (``refuseIfDocumentFile(_:document:)``) or, for a composed set, any drawing it was
    /// composed from.
    ///
    /// File ▸ Export Marked, Clean and Annotated PDF ask here before either writer runs. Marked
    /// export's structure-preserving path compared its destination only with its own staging file
    /// and then replaced the destination, so choosing the drawing in the panel replaced it with
    /// drawing + baked ink; and for a set every writer compared only with the temporary composed
    /// file (S-060). This used to check the drawing and the set's sources only — a narrower rule
    /// than the ledger, snippet and report exports had — so Replace in the panel overwrote a
    /// revision the person had dropped on the drawing, the only copy of it in a Quick PDF (V-021).
    /// One rule now decides which files no output may replace.
    @MainActor
    static func refuseIfSource(_ output: URL, document: ZenitPDFProjectDocument, set: DrawingSetOutput?) throws {
        try refuseIfDocumentFile(output, document: document)
        for source in set?.sources ?? [] {
            try refuseIfSource(output, source: source)
        }
    }

    /// Every file the document is made of that an output must never replace: its drawings — the
    /// primary and each one added to the set — the revisions dropped on it, and the document's
    /// own file (a Quick PDF's is its drawing).
    @MainActor
    static func documentFiles(of document: ZenitPDFProjectDocument) -> [URL] {
        var files = [document.drawing?.url, document.fileURL].compactMap { $0 }
        files += document.drawingSet?.members.map(\.drawing.url) ?? []
        files += document.revisionPages.values.compactMap(\.fileURL)
        return files
    }

    /// Throws ``Refusal`` when `output` is any file the document is made of
    /// (``documentFiles(of:)``) or lies inside its project package (U-017, U-018).
    ///
    /// The drawing exports asked ``refuseIfSource(_:document:set:)`` since S-060; the ledger
    /// export, Export Snippet, the review report, the Set Compare Report and the scripted
    /// `export ledger` did not, so choosing the Quick PDF's own Plan.pdf — in a save panel's
    /// Replace, or from a script with no panel at all — replaced the drawing with a report.
    @MainActor
    static func refuseIfDocumentFile(_ output: URL, document: ZenitPDFProjectDocument) throws {
        for source in documentFiles(of: document) {
            try refuseIfSource(output, source: source)
        }
        if let package = document.projectPackage?.url, SaveAsCarryOver.isInside(output, package) {
            throw Refusal(drawingName: package.lastPathComponent)
        }
    }
}
