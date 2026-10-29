import AppKit
import Foundation
import Observation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell

/// The Inspector's parameter rows (NL-MEASURE-07): depth, heights and slope of the selected
/// measurements, edited in place, and their Display units (NL-MEASURE-10, ADR-0035 §1.3). Each commit is one `editParameters` step over the selection
/// (one ⌘Z, one History entry per markup), recomputed by the engine; "Pick Fall Line…" takes two
/// clicks on the sheet and sets the slope's direction.
extension ProjectWindowController {

    func wireInspectorParameters(core: AppCoreEnvironment, shell: ProjectShellEnvironment, for document: ZenitPDFProjectDocument) {
        let editing = shell.inspectorEditing
        editing.onEditParameter = { [weak core, weak shell] ids, rowID, text in
            guard let core, let shell, let kind = MeasurementParameterRowKind(rawValue: rowID) else { return }
            Task { @MainActor in
                await Self.commitParameter(kind, text: text, ids: ids, core: core, editing: shell.inspectorEditing)
            }
        }
        editing.onPickFallLine = { [weak self, weak document] ids in
            guard let self, let document, let core = document.core else { return }
            FallLinePick.arm(document, markups: ids)
            document.pendingScaleCalibration = nil
            self.beginCalibration(for: document)
            core.status.setActiveToolNote(NSLocalizedString(
                "Pick Fall Line: click the low point, then the high point.",
                comment: "Status note while picking a slope's fall line"
            ))
        }
        // NL-MEASURE-09: the Caption row, each change one undoable style edit.
        editing.onSetCaptionFields = { [weak core] ids, fields in
            guard let core else { return }
            let chosen = fields.map { Domain.Field(shown: $0) }
            Self.editCaption(ids: ids, core: core, action: NSLocalizedString("Change Caption", comment: "Undo action name: caption fields changed")) {
                $0.fields = chosen
            }
        }
        editing.onSetSegmentLengths = { [weak core] ids, on in
            guard let core else { return }
            Self.editCaption(ids: ids, core: core, action: NSLocalizedString("Change Caption", comment: "Undo action name: caption fields changed")) {
                $0.showsSegmentLengths = on
            }
        }
        editing.onResetLabelPosition = { [weak core] ids in
            guard let core else { return }
            Self.editCaption(ids: ids, core: core, action: NSLocalizedString("Reset Label Position", comment: "Undo action name: a dragged caption put back")) {
                $0.labelOffset = nil
            }
        }
        editing.onRecalculateStale = { [weak document] in
            guard let document else { return }
            Self.recalculateStale(for: document)
        }
        observeSelectionForParameters(core: core, editing: editing)
        Self.refreshParameterRows(core: core, editing: editing)
    }

    /// Measure ▸ Recalculate Stale Measurements, and the Inspector's Recalculate (NL-MEASURE-03):
    /// every value kept under an older scale version, brought current in one undoable step.
    static func recalculateStale(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        Task { @MainActor in
            let count = await core.session.staleMeasurementIDs.count
            guard count > 0 else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "No measurement is kept under an older scale.",
                    comment: "Status note: Recalculate Stale found nothing to do"
                ))
                return
            }
            do {
                try await core.commands.recalculateStale()
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString("%lld measurements recalculated at the current scale.", comment: "Status note after Recalculate Stale; the count"),
                    Int64(count)
                ))
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }

    /// Re-reads the rows whenever the selection changes (from the canvas or the ledger) or the
    /// document does (an undo, a unit change): both are observed, so no refresh hook is needed.
    private func observeSelectionForParameters(core: AppCoreEnvironment, editing: InspectorEditing) {
        withObservationTracking {
            _ = core.canvas.selectedMarkupIDs
            _ = core.snapshot
        } onChange: { [weak self, weak core, weak editing] in
            Task { @MainActor in
                guard let self, let core, let editing else { return }
                Self.refreshParameterRows(core: core, editing: editing)
                self.observeSelectionForParameters(core: core, editing: editing)
            }
        }
    }

    /// Rebuilds the rows for the current selection.
    static func refreshParameterRows(core: AppCoreEnvironment, editing: InspectorEditing) {
        let ids = core.canvas.selectedMarkupIDs
        let unit = core.snapshot.units.length
        Task { @MainActor in
            var records: [MarkupRecord] = []
            for id in ids {
                if let record = await core.session.markup(MarkupID(id)) { records.append(record) }
            }
            // The selection may have moved while the records were read.
            guard core.canvas.selectedMarkupIDs == ids else { return }
            let rows = inspectorRows(for: records, lengthUnit: unit)
            if editing.parameterRowsSelection != ids { editing.parameterRefusal = nil }
            editing.parameterRows = rows
            editing.parameterRowsSelection = ids
            editing.captionState = captionState(records: records, ids: ids, snapshot: core.snapshot)
        }
    }

    /// The value rows, then the Display units row (NL-MEASURE-10), as the Inspector shows them.
    static func inspectorRows(for records: [MarkupRecord], lengthUnit: ZPDFUIPresentation.LengthUnit) -> [InspectorParameterRowModel] {
        let rows = ParameterEditing.rows(for: records, lengthUnit: lengthUnit) + [ParameterEditing.displayUnitsRow(for: records)].compactMap { $0 }
        return rows.map { row in
            InspectorParameterRowModel(
                id: row.kind.rawValue,
                title: row.kind.title,
                text: row.text,
                isMixed: row.isMixed,
                unitSymbol: row.unitSymbol,
                help: help(for: row.kind),
                choices: row.choices.map { InspectorParameterChoice(id: $0.id, title: $0.title) }
            )
        }
    }

    private static func help(for kind: MeasurementParameterRowKind) -> String {
        switch kind {
        case .slope:
            return NSLocalizedString("A slope as 6:12, 26.57°, 50 % or 0.5.", comment: "Help for the Inspector slope field")
        case .displayUnits:
            return NSLocalizedString(
                "The units this markup's ledger row and exports show. Totals still add up in the project's units.",
                comment: "Help for the Inspector Display units menu"
            )
        case .depth, .height, .heightAtEnd:
            return ""
        }
    }

    /// The Caption row for the selected measurements, or `nil` when the selection has none.
    static func captionState(records: [MarkupRecord], ids: Set<UUID>, snapshot: DocumentSnapshot) -> InspectorCaptionState? {
        guard !records.isEmpty, records.allSatisfy({ $0.tool != nil && $0.tool != .count && $0.parentMarkupID == nil }) else { return nil }
        let summaries = snapshot.markups.filter { ids.contains($0.id) }
        guard summaries.count == records.count, let first = summaries.first else { return nil }
        let common = summaries.dropFirst().reduce(Set(first.measurementFields.map(\.field))) { $0.intersection($1.measurementFields.map(\.field)) }
        let available = first.measurementFields.map(\.field).filter { common.contains($0) }
        let choices = Set(records.map { $0.style.measurementCaption?.fields ?? [] })
        let segments = Set(records.map { $0.style.measurementCaption?.showsSegmentLengths ?? false })
        let headlines = Set(summaries.compactMap { $0.measurementKind?.primaryField })
        return InspectorCaptionState(
            selection: ids,
            availableFields: available,
            chosenFields: choices.count == 1 ? choices.first.map { $0.compactMap { Shown.Field(domain: $0) } } : nil,
            headline: headlines.count == 1 ? headlines.first : nil,
            offersSegmentLengths: records.allSatisfy { MeasurementCaptionText.offersSegmentLengths($0.tool) },
            showsSegmentLengths: segments.count == 1 ? segments.first : nil,
            hasLabelOffset: records.contains { $0.style.measurementCaption?.labelOffset != nil }
        )
    }

    /// Writes one caption change over the selection as one step.
    static func editCaption(ids: Set<UUID>, core: AppCoreEnvironment, action: String, _ edit: @escaping (inout MeasurementCaption) -> Void) {
        Task { @MainActor in
            var records: [MarkupRecord] = []
            for id in ids {
                if let record = await core.session.markup(MarkupID(id)) { records.append(record) }
            }
            let commands = MeasurementCaptionText.commands(on: records, edit)
            guard !commands.isEmpty else { return }
            do {
                try await core.commands.performBatch(commands, actionName: action)
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }

    /// Writes one row over the selection, or says why not.
    static func commitParameter(
        _ kind: MeasurementParameterRowKind,
        text: String,
        ids: Set<UUID>,
        core: AppCoreEnvironment,
        editing: InspectorEditing
    ) async {
        var records: [MarkupRecord] = []
        for id in ids {
            if let record = await core.session.markup(MarkupID(id)) { records.append(record) }
        }
        do {
            let commands = try ParameterEditing.commands(setting: kind, to: text, on: records, lengthUnit: core.snapshot.units.length)
            editing.parameterRefusal = nil
            guard !commands.isEmpty else { return }
            try await core.commands.performBatch(
                commands,
                actionName: String(format: NSLocalizedString("Edit %@", comment: "Undo action name: a measurement parameter edited; the parameter"), kind.title)
            )
        } catch let refusal as ParameterEditing.Refusal {
            switch refusal {
            case .unreadable:
                switch kind {
                case .slope:
                    editing.parameterRefusal = NSLocalizedString("That is not a slope. Type it as 6:12, 26.57°, 50 % or 0.5.", comment: "Inspector refusal: unreadable slope")
                case .displayUnits:
                    editing.parameterRefusal = NSLocalizedString("Those display units are not offered here.", comment: "Inspector refusal: unknown display units choice")
                case .depth, .height, .heightAtEnd:
                    editing.parameterRefusal = NSLocalizedString("That is not a number.", comment: "Inspector refusal: unreadable length")
                }
            case .notPositive:
                editing.parameterRefusal = NSLocalizedString("The value must be greater than zero.", comment: "Inspector refusal: zero or negative parameter")
            }
        } catch {
            editing.parameterRefusal = String(describing: error)
        }
    }
}

/// Two clicks that set a slope's fall line (NL-MEASURE-07), the same pick Verify Scale uses.
@MainActor
enum FallLinePick {

    private static var pending: [UUID: Set<UUID>] = [:]

    static func arm(_ document: ZenitPDFProjectDocument, markups: Set<UUID>) {
        PendingPointPicks.disarmAll(document)
        pending[document.documentIdentity] = markups
    }

    static func isArmed(_ document: ZenitPDFProjectDocument) -> Bool { pending[document.documentIdentity] != nil }

    static func disarm(_ document: ZenitPDFProjectDocument) { pending[document.documentIdentity] = nil }

    /// The two points arrived: low point first, high point second.
    static func finish(points: [PDFPointValue], document: ZenitPDFProjectDocument) async {
        guard let ids = pending.removeValue(forKey: document.documentIdentity),
              points.count == 2, let core = document.core else { return }
        var records: [MarkupRecord] = []
        for id in ids {
            if let record = await core.session.markup(MarkupID(id)) { records.append(record) }
        }
        do {
            let commands = try ParameterEditing.fallLineCommands(
                from: PDFPoint(shown: points[0]), to: PDFPoint(shown: points[1]), on: records
            )
            guard !commands.isEmpty else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "Set the slope first; a fall line gives a slope its direction.",
                    comment: "Pick Fall Line refusal: no sloped markup selected"
                ))
                return
            }
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString("Set Fall Line", comment: "Undo action name: a slope's direction set")
            )
            core.status.setActiveToolNote(NSLocalizedString("Fall line set.", comment: "Status note after Pick Fall Line"))
        } catch {
            ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
        }
    }
}
