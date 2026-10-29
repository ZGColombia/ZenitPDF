import AppKit
import Foundation
import ZPDFAppCore
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// What the drawing's digital signatures say, shown when it opens (NL-PDF-15).
///
/// A sealed drawing in permit review is common, and a markup tool that silently breaks the seal
/// is a daily annoyance. So a signed drawing says, as soon as it opens, who signed it, when, and
/// whether the signed bytes are still exactly what was signed — verified offline by
/// `SignatureInspector` (the Security framework's CMS decoder over the `/ByteRange` bytes, trust
/// evaluated with network fetching off) — and which of Zenit's outputs keep the signature valid.
///
/// The row is a status note in the warning tray, the panel where the app already states facts
/// about the drawing file ("The drawing file says 1:100."); its lines are built by
/// ``lines(for:dateFormatter:)``, a pure function a document-information panel can show too.
@MainActor
enum DrawingSignatureStatus {

    /// One signature, reduced to what a sentence needs.
    struct Line: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case intact, intactWithLaterRevisions, modified, unverifiable
        }
        var signer: String?
        var signingTime: Date?
        var state: State
        var certificateTrusted: Bool

        init(signer: String?, signingTime: Date?, state: State, certificateTrusted: Bool) {
            self.signer = signer
            self.signingTime = signingTime
            self.state = state
            self.certificateTrusted = certificateTrusted
        }

        init(_ signature: SignatureInspector.Signature) {
            let state: State
            switch signature.integrity {
            case .intact: state = .intact
            case .intactWithLaterRevisions: state = .intactWithLaterRevisions
            case .modified: state = .modified
            case .unverifiable: state = .unverifiable
            }
            self.init(signer: signature.signer, signingTime: signature.signingTime, state: state,
                      certificateTrusted: signature.certificateTrusted)
        }
    }

    static func stateText(_ state: Line.State) -> String {
        switch state {
        case .intact:
            NSLocalizedString("intact", comment: "Signature state: the signed bytes are unchanged")
        case .intactWithLaterRevisions:
            NSLocalizedString("intact, with changes added after it", comment: "Signature state: signed revision unchanged, later revisions appended")
        case .modified:
            NSLocalizedString("modified after signing", comment: "Signature state: the signed bytes changed")
        case .unverifiable:
            NSLocalizedString("could not be checked", comment: "Signature state: signature unreadable")
        }
    }

    /// "Signed by Jane Engineer on 23 Sep 2026 — intact", one per signature. Pure.
    static func lines(for signatures: [Line], dateFormatter: DateFormatter) -> [String] {
        signatures.map { signature in
            let who = signature.signer ?? NSLocalizedString("an unreadable certificate", comment: "Signer name when the certificate cannot be read")
            let base: String
            if let time = signature.signingTime {
                base = String(format: NSLocalizedString("Signed by %1$@ on %2$@", comment: "Signature line; signer, date"), who, dateFormatter.string(from: time))
            } else {
                base = String(format: NSLocalizedString("Signed by %@", comment: "Signature line without a date; signer"), who)
            }
            return base + " — " + stateText(signature.state)
        }
    }

    /// The tray note for `signatures`, or `nil` for an unsigned drawing. Pure.
    static func note(for signatures: [Line], dateFormatter: DateFormatter, id: UUID = UUID(), now: Date = Date()) -> AppWarning? {
        guard !signatures.isEmpty else { return nil }
        let rows = lines(for: signatures, dateFormatter: dateFormatter)
        let broken = signatures.contains { $0.state == .modified || $0.state == .unverifiable }
        let title: String
        if signatures.count == 1, let row = rows.first {
            title = row
        } else {
            let intact = signatures.filter { $0.state == .intact || $0.state == .intactWithLaterRevisions }.count
            title = String(
                format: NSLocalizedString("%1$lld signatures: %2$lld intact, %3$lld not.", comment: "Several signatures headline; total, intact, broken"),
                Int64(signatures.count), Int64(intact), Int64(signatures.count - intact)
            )
        }
        var parts: [String] = signatures.count > 1 ? rows : []
        if signatures.contains(where: { !$0.certificateTrusted && $0.state != .unverifiable }) {
            parts.append(NSLocalizedString(
                "The certificate does not lead to one this Mac trusts, so the signature proves the drawing is unchanged, not who issued the certificate. Nothing was looked up online.",
                comment: "Signature note: untrusted certificate, checked offline"
            ))
        }
        parts.append(broken
            ? NSLocalizedString(
                "The drawing changed after it was signed. Ask the sender for the signed original before relying on it.",
                comment: "Signature note: modified"
            )
            : NSLocalizedString(
                "Save Markups into PDF and the annotated export add to the end of the file and keep the signature valid; Marked, Clean and Layered exports make a new file without it.",
                comment: "Signature note: which outputs keep it"
            ))
        return AppWarning(
            id: id,
            severity: broken ? .warning : .info,
            title: title,
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Signatures", comment: "Warning source: digital signatures of the drawing"),
            isDismissible: true,
            timestamp: now
        )
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Reads the drawing's signatures off the main actor and posts the note.
    static func post(for document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing, let core = document.core else { return }
        let url = drawing.url
        Task { @MainActor [weak document] in
            let found = await Task.detached(priority: .utility) {
                SignatureInspector.signatures(ofFileAt: url).map(Line.init)
            }.value
            guard let document, document.core === core,
                  let note = note(for: found, dateFormatter: dateFormatter) else { return }
            core.document.post(note)
        }
    }
}
