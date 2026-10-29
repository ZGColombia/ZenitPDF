import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// What one Apply-mode action did, as a value the panel and the status bar can report.
///
/// A receipt rather than a `Bool`, because an incompatible preset must say **which
/// properties it skipped** rather than half-applying in silence. That
/// sentence cannot be produced from a success flag, so the outcome carries it.
public struct ToolPresetApplyReceipt: Hashable, Sendable {

    /// The markups whose stored record changed.
    public var changedMarkupIDs: Set<UUID>
    /// The markups whose measurement was recomputed, a subset of ``changedMarkupIDs``.
    public var recomputedMarkupIDs: Set<UUID>
    /// How many audit entries the action wrote — one per affected markup (ADR-0007 §2).
    public var auditEntryCount: Int
    /// Properties the preset carried that some target could not take, de-duplicated.
    ///
    /// The **union** across the whole action, kept because the audit note and the one-line
    /// summary both want "which properties did this preset fail to write anywhere". It is not
    /// what the person reads: see ``skipReport``.
    public var skipped: [ToolPresetSkip]
    /// What each markup could not take, grouped so a repeated answer is one line with a count.
    ///
    /// Applying one preset across a mixed selection used to report only ``skipped`` — the
    /// union — so twelve markups that each dropped a different property produced one merged
    /// list and no way to tell which markup dropped what. This is the per-markup answer, and
    /// the grouping is what keeps it legible: twelve identical skips are one line saying
    /// twelve, and the odd markup keeps its own line instead of disappearing into the union.
    public var skipReport: MarkupSkipReport
    /// The Edit-menu name of the single undo step this action left behind.
    public var undoActionName: String
    /// Why nothing happened, when nothing happened.
    public var failureMessage: String?

    /// Creates a receipt.
    public init(
        changedMarkupIDs: Set<UUID> = [],
        recomputedMarkupIDs: Set<UUID> = [],
        auditEntryCount: Int = 0,
        skipped: [ToolPresetSkip] = [],
        skipReport: MarkupSkipReport = MarkupSkipReport(skips: []),
        undoActionName: String = "",
        failureMessage: String? = nil
    ) {
        self.changedMarkupIDs = changedMarkupIDs
        self.recomputedMarkupIDs = recomputedMarkupIDs
        self.auditEntryCount = auditEntryCount
        self.skipped = skipped
        self.skipReport = skipReport
        self.undoActionName = undoActionName
        self.failureMessage = failureMessage
    }

    /// A refusal with a stated reason.
    public static func failure(_ reason: String) -> ToolPresetApplyReceipt {
        ToolPresetApplyReceipt(failureMessage: reason)
    }

    /// Whether the action changed anything.
    public var didChangeAnything: Bool { !changedMarkupIDs.isEmpty }

    /// One sentence for the status bar: what changed, what recomputed, what was skipped.
    ///
    /// The skip list is part of the *same* sentence rather than a separate warning, because a
    /// person who applied a preset and saw "12 markups updated" would reasonably assume the
    /// whole preset landed on all twelve.
    public var summaryMessage: String {
        if let failureMessage { return failureMessage }
        guard didChangeAnything else {
            return NSLocalizedString(
                "Nothing changed: those markups already carry this tool's properties.",
                comment: "Apply-mode result when every property already matched"
            )
        }
        var sentence = String(
            format: NSLocalizedString(
                "Applied to %d markups.",
                comment: "Apply-mode result. %d is the number of markups changed"
            ),
            changedMarkupIDs.count
        )
        if !recomputedMarkupIDs.isEmpty {
            sentence += " " + String(
                format: NSLocalizedString(
                    "%d were recomputed.",
                    comment: "Apply-mode result. %d is the number of measurements recomputed"
                ),
                recomputedMarkupIDs.count
            )
        }
        // Per markup, grouped — not the union. `MarkupSkipReport` already collapses identical
        // answers into one counted line, so twelve areas that all dropped Depth read as
        // "12 markups skipped Depth." and the one that also dropped Wall height keeps its own
        // line. The union sentence that used to be here could not express the difference.
        if !skipReport.isEmpty {
            sentence += " " + skipReport.summarySentence
        }
        return sentence
    }
}

/// Apply mode: a preset used as a brush over existing markups.
///
/// Deliberately built on the same three mechanisms the ledger's bulk edit uses, because the
/// three promises are the same and a second implementation of them is how the two drift:
///
/// - **One undo.** Every property of every markup becomes one command, and the whole list goes
///   through ``DocumentCommandBus/performBatch(_:actionName:)``. Applying "Slab 200 mm" to
///   twelve areas is one ⌘Z, not twelve.
/// - **One audit entry per affected markup**, under one `undo_group` (ADR-0007 §2). Twelve
///   provenance-carrying changes, so a dispute about area seven has an answer.
/// - **Recomputation through the engine.** A property that feeds the maths goes out as
///   ``DocumentCommand/editParameters(id:parameters:)``, which `TakeoffSession` applies with
///   `recomputes: true` — the same path an edited vertex takes. Nothing here writes a number.
///
/// And one promise the bulk edit does not have to make: **geometry is never touched.** No
/// command this function can emit changes a point. ``ToolPresetApplicability`` has no name for
/// geometry, so there is nothing to write it through.
extension AppCoreEnvironment {

    /// The Edit-menu name of an Apply-mode action.
    ///
    /// Not the name of whichever command happened to be last: "Undo Change Style" over a step
    /// that also re-cut twelve volumes is a lie about what ⌘Z is about to do.
    public static var applyPresetUndoActionName: String {
        NSLocalizedString(
            "Apply Tool Properties",
            comment: "Undo action name for applying a tool preset over a selection"
        )
    }

    /// The name a custom column default goes by in a skip report.
    static func customDefaultSkipName(_ key: String) -> String {
        String(
            format: NSLocalizedString(
                "%1$@ “%2$@”",
                comment: "A custom column default a preset could not write. %1$@ is the property name (Custom values), %2$@ the column"
            ),
            ToolPresetProperty.customValues.displayName,
            key
        )
    }

    /// Writes a preset's properties onto every markup in a selection, as one undoable action.
    ///
    /// - Parameters:
    ///   - preset: the armed preset, used as a brush.
    ///   - markupIDs: the selection. One id is the ordinary single click; many is the bulk case
    ///     this exists for.
    public func applyPreset(
        _ preset: ToolPresetSummary,
        to markupIDs: Set<UUID>
    ) async -> ToolPresetApplyReceipt {
        guard !markupIDs.isEmpty else {
            return .failure(NSLocalizedString(
                "Select a markup first: Apply writes this tool's properties onto markups that already exist.",
                comment: "Apply-mode refusal with an empty selection"
            ))
        }

        // Sorted, so the command order — and therefore the audit order inside the step — is
        // reproducible rather than whatever order the `Set` hashed into.
        let ids = markupIDs.sorted { $0.uuidString < $1.uuidString }.map { MarkupID($0) }
        let customDefaults = Self.resolvedCustomValues(
            preset.customDefaults,
            columns: await session.ledgerColumns,
            currencyCode: ledger.defaultCurrencyCode
        )

        var records: [MarkupID: MarkupRecord] = [:]
        var lockedCount = 0
        for id in ids {
            guard let record = await session.markup(id) else { continue }
            if record.locked { lockedCount += 1 } else { records[id] = record }
        }

        // Locked markups refuse the whole batch, out loud. Skipping them quietly would leave
        // the estimator believing forty rows were reclassified when thirty-eight were.
        if lockedCount > 0 {
            return .failure(String(
                format: NSLocalizedString(
                    "Nothing was changed: %d of the selected markups are locked. Unlock them and try again.",
                    comment: "Apply-mode refusal; the placeholder is the number of locked markups"
                ),
                lockedCount
            ))
        }
        guard !records.isEmpty else {
            return .failure(NSLocalizedString(
                "Nothing was changed: the selected markups are no longer in the document.",
                comment: "Apply-mode refusal when the selection has gone stale"
            ))
        }

        var batch: [DocumentCommand] = []
        var statusTargets: [MarkupID] = []
        var recomputed: Set<UUID> = []
        // Two accounts of the same facts, deliberately. `skipped` is the union — the distinct
        // properties this preset failed to write anywhere — and feeds the receipt's property
        // list. `markupSkips` is one entry per markup and is what the person reads, because
        // the union cannot say *which* markups.
        var skipped: [ToolPresetProperty: ToolPresetSkip] = [:]
        var markupSkips: [MarkupSkipReport.Skip] = []

        for id in ids {
            guard let record = records[id] else { continue }
            let plan = ToolPresetApplicability.plan(
                preset: preset,
                targetKind: Shown.Markup(domain: record.kind),
                targetTool: record.tool.map { Shown.Kind(domain: $0) }
            )
            for skip in plan.skipped where skipped[skip.property] == nil {
                skipped[skip.property] = skip
            }
            if !plan.skipped.isEmpty {
                markupSkips.append(MarkupSkipReport.Skip(
                    markupID: id.rawValue,
                    propertyNames: plan.skipped.map(\.property.displayName)
                ))
            }

            if plan.applicable.contains(.subject), record.subject != preset.defaultSubject {
                batch.append(.editSubject(id: id, subject: preset.defaultSubject))
            }
            if plan.applicable.contains(.label), record.label != preset.labelPattern {
                batch.append(.editLabel(id: id, label: preset.labelPattern))
            }
            if plan.applicable.contains(.color) {
                let target = RGBAColor(shown: preset.colorRGBA)
                if record.style.color != target {
                    var style = record.style
                    style.color = target
                    batch.append(.changeStyle(id: id, style: style))
                }
            }
            if plan.applicable.contains(.customValues) {
                for (column, domain) in customDefaults.values.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                where record.customValues[column] != domain {
                    batch.append(.editCustomValue(id: id, column: column, value: domain))
                }
                // A value the column cannot hold — "2" for a choice column with no option "2",
                // text for a number column — or a key the document has no column for is reported, per markup,
                // like every other property the preset could not write (BH-116).
                if !customDefaults.skipped.isEmpty {
                    let names = customDefaults.skipped.map(Self.customDefaultSkipName)
                    if skipped[.customValues] == nil {
                        skipped[.customValues] = ToolPresetSkip(
                            property: .customValues,
                            targetToolName: plan.skipped.first?.targetToolName
                                ?? record.tool.map { Shown.Kind(domain: $0).displayName }
                                ?? Shown.Markup(domain: record.kind).displayName
                        )
                    }
                    if let index = markupSkips.firstIndex(where: { $0.markupID == id.rawValue }) {
                        let existing = markupSkips[index]
                        markupSkips[index] = MarkupSkipReport.Skip(
                            markupID: existing.markupID,
                            propertyNames: existing.propertyNames + names
                        )
                    } else {
                        markupSkips.append(MarkupSkipReport.Skip(markupID: id.rawValue, propertyNames: names))
                    }
                }
            }
            if plan.applicable.contains(.status) {
                let target = Domain.Status(shown: preset.defaultStatus)
                if record.status != target { statusTargets.append(id) }
            }

            // The measurement half. Only the properties the plan allowed are layered in, so a
            // Length preset dropped on an Area writes no depth rather than a depth an area
            // cannot use — and the skip list above already says so.
            if plan.recomputes {
                let parameters = ToolPresetParameterBridge.parameters(
                    applying: preset.measurementDefaults,
                    onto: record.parameters ?? .default,
                    writing: plan.applicable
                )
                if parameters != (record.parameters ?? .default) {
                    batch.append(.editParameters(id: id, parameters: parameters))
                    recomputed.insert(id.rawValue)
                }
            }
        }

        if !statusTargets.isEmpty {
            batch.append(.batchStatusChange(
                ids: statusTargets, status: Domain.Status(shown: preset.defaultStatus)
            ))
        }

        let actionName = Self.applyPresetUndoActionName
        let skips = skipped.values.sorted { $0.property.rawValue < $1.property.rawValue }
        let report = MarkupSkipReport(skips: markupSkips)
        guard !batch.isEmpty else {
            // Every property already held the value the preset asked for. Nothing to undo and
            // nothing to record — an audit entry saying "changed nothing" is noise in the one
            // place noise is expensive.
            return ToolPresetApplyReceipt(skipped: skips, skipReport: report, undoActionName: actionName)
        }

        do {
            guard let outcome = try await commands.performBatch(batch, actionName: actionName) else {
                return ToolPresetApplyReceipt(skipped: skips, skipReport: report, undoActionName: actionName)
            }
            let changed = Set(outcome.changedMarkupIDs.map(\.rawValue))
            return ToolPresetApplyReceipt(
                changedMarkupIDs: changed,
                recomputedMarkupIDs: recomputed.intersection(changed),
                auditEntryCount: history.isAttached ? changed.count : 0,
                skipped: skips,
                skipReport: report,
                undoActionName: actionName
            )
        } catch {
            return .failure(String(describing: error))
        }
    }

}
