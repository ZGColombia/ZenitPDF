import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The ledger's bulk edit, turned into document commands.
///
/// Multi-selection editing is most of a real review day: a reviewer
/// selects nineteen rows, sets their status, retypes a subject, recolours them, and expects
/// exactly one Cmd-Z to take the whole thing back. That expectation is the design:
///
/// - **One step.** Every field of every markup becomes one command, and the whole list goes
///   through ``DocumentCommandBus/performBatch(_:actionName:)`` — one undo entry, one redo
///   entry, atomic in the session.
/// - **One entry per markup.** The audit fan-out writes a `measurement_audit` row for each
///   affected markup under a single `undo_group` (ADR-0007 §2), so a dispute about markup
///   seven has an answer.
/// - **No silent no-ops.** A field whose value already matches produces no command, so the
///   undo entry covers what actually changed rather than nineteen identity writes.
/// - **Locked markups refuse the batch, out loud.** Skipping them quietly would leave the
///   reviewer believing nineteen rows changed when eighteen did.
extension AppCoreEnvironment {

    /// The Edit-menu name of a bulk edit. Deliberately not the name of whichever command
    /// happened to be last: "Undo Change Status" over a step that also rewrote four
    /// subjects and a colour is a lie about what Cmd-Z is about to do.
    public static var bulkEditUndoActionName: String {
        NSLocalizedString("Bulk Edit", comment: "Undo action name for a multi-selection ledger edit")
    }

    /// Applies one bulk edit as a single undoable step.
    ///
    /// Wired to ``AppLedgerPresenter/onBulkEdit`` by the environment, which is the only
    /// place that knows both the ledger's vocabulary and the command bus. The presenter
    /// itself never reaches the session — a second write path into the document is exactly
    /// what ``DocumentCommandBus`` exists to prevent.
    public func applyBulkEdit(_ request: LedgerBulkEditRequest) async -> LedgerBulkEditReceipt {
        guard !request.isEmpty else { return LedgerBulkEditReceipt() }

        // Sorted, so the command order — and therefore the audit order inside the step —
        // is reproducible rather than whatever order the `Set` hashed into.
        let ids = request.markupIDs
            .sorted { $0.uuidString < $1.uuidString }
            .map { MarkupID($0) }

        let columns = await session.ledgerColumns
        var records: [MarkupID: MarkupRecord] = [:]
        var lockedCount = 0
        var missingCount = 0
        var derivedCount = 0
        for id in ids {
            guard let record = await session.markup(id) else {
                // ADR-0012 rule 1 / ADR-0024: a derived row is computed from its measured row
                // and is never edited as itself; saying "no longer in the document" would be
                // wrong about why.
                if await session.isDerivedRow(id) { derivedCount += 1 } else { missingCount += 1 }
                continue
            }
            if record.locked {
                lockedCount += 1
            } else {
                records[id] = record
            }
        }

        if derivedCount > 0 {
            return .failure(Self.derivedRefusal(count: derivedCount))
        }
        if lockedCount > 0 {
            return .failure(String(
                format: NSLocalizedString(
                    "Nothing was changed: %d of the selected markups are locked. Unlock them and try again.",
                    comment: "Bulk edit refusal; the placeholder is the number of locked markups"
                ),
                lockedCount
            ))
        }
        guard !records.isEmpty else {
            return .failure(NSLocalizedString(
                "Nothing was changed: the selected markups are no longer in the document.",
                comment: "Bulk edit refusal when the selection has gone stale"
            ))
        }
        // Part of the selection has gone — deleted from another window before Apply. The
        // receipt has no way to name skipped rows, so the batch is refused as a whole, like a
        // locked row refuses it: sixteen changed out of nineteen with a success receipt is
        // the quiet partial application this file exists to prevent (BH-447).
        if missingCount > 0 {
            return .failure(String(
                format: NSLocalizedString(
                    "Nothing was changed: %d of the selected markups are no longer in the document. Select the rows again and retry.",
                    comment: "Bulk edit refusal when part of the selection has gone; the placeholder is the number missing"
                ),
                missingCount
            ))
        }
        let newStatus: ZPDFContracts.MarkupStatus? = {
            guard case let .choice(stored)? = request.values[.status] else {
                return ZPDFContracts.MarkupStatus?.none
            }
            return ZPDFContracts.MarkupStatus(rawValue: stored)
        }()
        // NL-QTY-01: every column other than the four with commands of their own is resolved
        // by its definition — a table import's `zenit.import.<uuid>`, the built-in Cost Code
        // or Unit Cost, a `custom.` column alike. The old test was the `custom.` prefix, so an
        // edit to any other column was dropped here and the call still returned a success
        // receipt with nothing changed.
        let ownCommands: Set<LedgerColumnID> = [.subject, .label, .comment, .status]
        var customEdits: [(key: LedgerColumnID, value: ZPDFUIPresentation.LedgerCellValue)] = []
        for (columnID, value) in request.values where !ownCommands.contains(columnID) {
            guard let definition = columns.column(key: columnID.rawValue) else {
                return .failure(String(
                    format: NSLocalizedString(
                        "Nothing was changed: the column “%@” is no longer in this project.",
                        comment: "Bulk edit refusal when an edited column has been removed; the placeholder is the column identifier"
                    ),
                    columnID.rawValue
                ))
            }
            guard LedgerBridge.holdsUserValues(definition) else {
                return .failure(String(
                    format: NSLocalizedString(
                        "Nothing was changed: “%@” is calculated or measured and cannot be typed into.",
                        comment: "Bulk edit refusal for a read-only column; the placeholder is the column title"
                    ),
                    LedgerBridge.title(of: definition)
                ))
            }
            customEdits.append((columnID, value))
        }
        customEdits.sort { $0.key.rawValue < $1.key.rawValue }
        // A value a column cannot hold is refused up front, naming the column, rather than
        // dropped per row in silence — a fractional or zero Repeat ×, text in a number column.
        for (columnID, value) in customEdits {
            guard let definition = columns.column(key: columnID.rawValue) else { continue }
            if LedgerBridge.domainCellValue(value, definition: definition) == nil {
                return .failure(String(
                    format: NSLocalizedString(
                        "Nothing was changed: “%@” cannot hold that value.",
                        comment: "Bulk edit refusal when a value does not fit its column; the placeholder is the column title"
                    ),
                    LedgerBridge.title(of: definition)
                ))
            }
        }


        var batch: [DocumentCommand] = []
        var statusTargets: [MarkupID] = []

        for id in ids {
            guard let record = records[id] else { continue }

            // `.empty` is how a cleared field arrives (the Inspector sends it when a label or
            // note is deleted, the ledger's cell editor when a cell is emptied); it writes the
            // empty string rather than being ignored. Subject read only `.text`, so clearing a
            // Subject cell changed nothing and still returned a success receipt (T-029) — the
            // spreadsheet round trip already cleared one the same way.
            if let subject = Self.text(request.values[.subject]), record.subject != subject {
                batch.append(.editSubject(id: id, subject: subject))
            }
            if let label = Self.text(request.values[.label]), record.label != label {
                batch.append(.editLabel(id: id, label: label))
            }
            if let comment = Self.text(request.values[.comment]), record.comment != comment {
                batch.append(.editComment(id: id, comment: comment))
            }
            for (columnID, value) in customEdits {
                guard let definition = columns.column(key: columnID.rawValue),
                      let domain = LedgerBridge.domainCellValue(value, definition: definition),
                      record.customValues[definition.id] != domain
                else { continue }
                batch.append(.editCustomValue(id: id, column: definition.id, value: domain))
            }
            // Appearance. One `.changeStyle` per markup however many fields moved, and none at
            // all when the markup already looks the way it is being asked to look — the same
            // "changed nothing is not a command" rule the fields above follow.
            var style = record.style
            if let color = request.color { style.color = RGBAColor(shown: color) }
            if let color = request.style.color { style.color = RGBAColor(shown: color) }
            if let width = request.style.lineWidth { style.lineWidth = width }
            if let opacity = request.style.opacity { style.opacity = opacity }
            // Cloud only where it draws as scallops; elsewhere it was a silent no-op.
            if let lineStyle = request.style.lineStyle,
               lineStyle != .cloud || MarkupStyleFit.holdsCloudStyle(record.kind) {
                style.lineStyle = lineStyle.domain
            }
            if let fontSize = request.style.fontSize { style.fontSize = fontSize }
            // Line ends only mean something on an open stroke, and a font or an
            // alignment only on a markup that draws words; `MarkupStyleFit` says which.
            if let cap = request.style.startCap, MarkupStyleFit.holdsLineEnds(record.kind) { style.startCap = cap.domain }
            if let cap = request.style.endCap, MarkupStyleFit.holdsLineEnds(record.kind) { style.endCap = cap.domain }
            if let font = request.style.fontName, MarkupStyleFit.holdsText(record.kind) { style.fontName = font }
            if let alignment = request.style.textAlignment, MarkupStyleFit.holdsText(record.kind) {
                style.textAlignment = alignment.domain
            }
            // ADR-0029: text formatting only where there are words, arc size only where the
            // outline scallops, rotation only on a kind that turns.
            if MarkupStyleFit.holdsText(record.kind) {
                var text = style.textStyle ?? .plain
                if let bold = request.style.bold { text.bold = bold }
                if let italic = request.style.italic { text.italic = italic }
                if let colour = request.style.textColor {
                    text.textColor = RGBAColor(shown: colour)
                } else if request.style.removesTextColor {
                    text.textColor = nil
                }
                if let border = request.style.boxBorder, record.kind == .text { text.boxBorder = border }
                style.textStyle = text == .plain ? nil : text
            }
            if let arc = request.style.cloudArcSize, arc.isFinite, arc > 0,
               MarkupStyleFit.holdsCloudStyle(record.kind) {
                style.cloudArcSize = min(MarkupStyle.cloudArcSizeRange.upperBound, max(MarkupStyle.cloudArcSizeRange.lowerBound, arc))
            } else if request.style.resetsCloudArcSize {
                style.cloudArcSize = nil
            }
            if let rotation = request.style.rotationDegrees, rotation.isFinite, MarkupStyleFit.holdsRotation(record) {
                let wrapped = rotation.truncatingRemainder(dividingBy: 360)
                let folded = wrapped < 0 ? wrapped + 360 : wrapped
                style.rotationDegrees = abs(folded) < 1e-9 ? nil : folded
            }
            if let fill = request.style.fill {
                // A fill only where there is an interior to draw it in.
                if MarkupStyleFit.holdsFill(record) { style.fill = RGBAColor(shown: fill) }
            } else if request.style.removesFill {
                style.fill = nil
            } else if style.color != record.style.color {
                // L-87: a new colour takes the area's fill along when the fill was the old
                // colour's tint, so the shape, its pill and its ledger swatch agree.
                style.fill = MarkupStyleFit.fill(record.style.fill, followingColourFrom: record.style.color, to: style.color)
            }
            if style != record.style {
                batch.append(.changeStyle(id: id, style: style))
            }
            if let newStatus, record.status != newStatus {
                statusTargets.append(id)
            }
        }

        // Status is the one field with a batch command of its own, so it stays one command
        // for the whole selection rather than nineteen.
        if let newStatus, !statusTargets.isEmpty {
            batch.append(.batchStatusChange(ids: statusTargets, status: newStatus))
        }

        // The Edit menu names what changed ("Undo Change Colour"), not "Bulk Edit"
        // for one colour on one markup. See `AppBulkEditActionName.swift`.
        let actionName = Self.undoActionName(for: request, markupCount: records.count)
        guard !batch.isEmpty else {
            // Every field already held the value the user asked for. Nothing to undo, and
            // nothing to record — an audit entry saying "changed nothing" is noise in the
            // one place noise is expensive.
            return LedgerBulkEditReceipt(undoActionName: actionName)
        }

        do {
            guard let outcome = try await self.commands.performBatch(batch, actionName: actionName) else {
                return LedgerBulkEditReceipt(undoActionName: actionName)
            }
            let changed = Set(outcome.changedMarkupIDs.map(\.rawValue))
            return LedgerBulkEditReceipt(
                changedMarkupIDs: changed,
                auditEntryCount: history.isAttached ? changed.count : 0,
                undoActionName: actionName
            )
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// The text a standard text column is being set to: the string for `.text`, the empty
    /// string for `.empty` (a cleared field), `nil` when the request leaves the column alone.
    static func text(_ value: ZPDFUIPresentation.LedgerCellValue?) -> String? {
        switch value {
        case let .text(text)?: return text
        case .empty?: return ""
        default: return nil
        }
    }
}
