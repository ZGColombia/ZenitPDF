import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Sheet identity in the session (NL-DOCS-05): named sheets, undoable, persisted.
///
/// The naming data model is owned here; the title-block *recognition* lives in the automation
/// layer (`Automation/TitleBlockReader.swift`, NL-AUTO-04), which hands its accepted proposals to
/// ``DocumentCommand/setSheetIdentities(_:overwriteManual:)`` with `overwriteManual: false`.
extension TakeoffSession {

    /// Every named sheet, keyed by page.
    public var sheetIdentities: [PageID: SheetIdentity] { sheetIdentityTable }

    /// The identity of one sheet, or `nil`.
    public func sheetIdentity(of page: PageID) -> SheetIdentity? { sheetIdentityTable[page] }

    /// Installs stored identities after an open. No undo step: this is the file, not an edit.
    /// Identities for pages this session does not hold are dropped.
    public func restoreSheetIdentities(_ identities: [PageID: SheetIdentity]) {
        let live = Set(pageOrderIDs)
        sheetIdentityTable = identities.filter { live.contains($0.key) && !$0.value.isEmpty }
    }

    func applySetSheetIdentities(
        _ requested: [PageID: SheetIdentity?],
        overwriteManual: Bool,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        let live = Set(pageOrderIDs)
        for page in requested.keys where !live.contains(page) {
            throw DocumentCommandError.unknownPage(page)
        }
        var inverse = DocumentCommandInverse()
        var previous: [PageID: SheetIdentity?] = [:]
        var changed: Set<PageID> = []
        for (page, identity) in requested {
            let existing = sheetIdentityTable[page]
            // A name a person typed is never replaced by an automatic reading.
            if !overwriteManual, existing?.source == .manual { continue }
            let next = (identity?.isEmpty ?? true) ? nil : identity
            guard next != existing else { continue }
            previous.updateValue(existing, forKey: page)
            sheetIdentityTable[page] = next
            changed.insert(page)
        }
        inverse.sheetIdentities = previous.isEmpty ? nil : previous
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [],
            changedPageIDs: changed
        )
    }

    /// The page whose sheet number is `number` (case- and space-insensitive), when exactly one
    /// page carries it. Two pages claiming it is an answer of "no": the caller must not guess.
    public func page(withSheetNumber number: String) -> PageID? {
        let wanted = SheetIdentityMatching.normalised(number)
        guard !wanted.isEmpty else { return nil }
        let hits = pageOrderIDs.filter { page in
            sheetIdentityTable[page]?.number.map(SheetIdentityMatching.normalised) == wanted
        }
        return hits.count == 1 ? hits[0] : nil
    }
}

/// How sheet numbers are compared: case, spaces and the separator style do not make a
/// different sheet ("a-101", "A 101", "A101" and "A-101" are one).
public enum SheetIdentityMatching {
    /// The one sheet-number rule, shared with the shell's page field (S-048).
    public static func normalised(_ number: String) -> String {
        ZPDFUIPresentation.PageDescriptor.normalisedSheetNumber(number)
    }
}
