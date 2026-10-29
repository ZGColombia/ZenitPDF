import Foundation
import ZPDFPDFKitBridge

/// One Apply Redactions: the assessment before the confirmation, then the copy, from a single
/// preparation (S-071).
///
/// ``VectorRedactor/assess(source:password:marks:)`` and
/// ``VectorRedactor/redact(source:password:marks:to:dpi:)`` each prepare the drawing: open it
/// in PDFKit, read the whole file, scan every object and rewrite every marked sheet at least
/// twice. Called one after the other for one redaction, that work ran twice. The session keeps
/// what ``assess(source:password:marks:)`` prepared and ``redact(source:password:marks:to:dpi:)``
/// uses it — once, since building the copy adds to it — when the source, the password and the
/// marks are the ones assessed and the file still holds exactly the bytes that were read. Anything
/// else prepares afresh, so a drawing changed on disk between the two is never redacted from its
/// old contents.
///
/// An actor, so the preparation (a PDFKit document and the rewrite context) never leaves the
/// isolation it was made in, and both steps run off the main thread.
public actor VectorRedactionSession {

    private struct Key: Equatable {
        var source: URL
        var password: String?
        var marks: [RedactionMark]
    }

    private var kept: (key: Key, prepared: VectorRedactor.Prepared)?
    /// How many times this session read and rewrote a drawing — one per Apply when the copy is
    /// built from the assessment's preparation.
    public private(set) var preparations = 0

    public init() {}

    /// Which marked sheets would stay vector; the preparation is kept for ``redact``.
    public func assess(source: URL, password: String? = nil, marks: [RedactionMark]) -> RedactionAssessment {
        kept = nil
        preparations += 1
        let prepared = try? VectorRedactor.prepare(source: source, password: password, marks: marks)
        if let prepared { kept = (Key(source: source, password: password, marks: marks), prepared) }
        return VectorRedactor.assessment(of: prepared, marks: marks)
    }

    /// Writes the redacted copy, from the assessed preparation when it still describes the drawing.
    public func redact(
        source: URL,
        password: String? = nil,
        marks: [RedactionMark],
        to output: URL,
        dpi: Double = RasterRedactor.defaultDPI
    ) throws -> RedactionOutcome {
        let candidate = kept
        kept = nil
        guard !marks.isEmpty else { throw RedactionRefusal.noMarks }
        try StagedFileReplacement.refuseOverwriting([source], with: output, refusal: RedactionRefusal.outputIsSource)
        let prepared: VectorRedactor.Prepared
        if let candidate, candidate.key == Key(source: source, password: password, marks: marks),
           let current = try? Data(contentsOf: source), current == candidate.prepared.sourceData {
            prepared = candidate.prepared
        } else {
            preparations += 1
            prepared = try VectorRedactor.prepare(source: source, password: password, marks: marks)
        }
        return try VectorRedactor.redact(prepared, source: source, password: password, marks: marks, to: output, dpi: dpi)
    }

    /// Lets go of a kept preparation — the person cancelled, or chose pictures instead.
    public func discard() {
        kept = nil
    }
}
