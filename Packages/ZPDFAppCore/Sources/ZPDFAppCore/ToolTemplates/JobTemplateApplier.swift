import Foundation
import ZPDFUIPresentation

/// Captures a template from a live configuration, and applies one to a project's presenters.
///
/// # What "apply" is allowed to touch
///
/// The applier takes the Tool Library presenter and the ledger presenter — the two surfaces a
/// rig lives on — and hands the units and subjects back to the caller in its receipt. It does
/// **not** take the command bus, the session or anything else that can reach a calibration:
/// the invariant that a template never applies a scale is kept here the same way it is kept in
/// ``JobTemplate`` itself, by there being no route from this code to a scale. The test that
/// proves it calibrates a real session, applies a template through this applier, and reads
/// every page's scale back bit-identical.
public enum JobTemplateApplier {

    // MARK: - Capture

    /// Captures the rig as it is configured right now.
    ///
    /// - Parameters:
    ///   - name: the template's name — the job type it stands for.
    ///   - toolLibrary: the Tool Library as armed and ordered on screen.
    ///   - ledger: the Quantity Ledger whose column visibility and order travel — as its table
    ///     shows them (``AppLedgerPresenter/tableArrangement``), not as the column definitions
    ///     declare them (W-029). Without a table, the presenter's own columns.
    ///   - units: the display units the rig presents results in.
    ///   - now: the capture instant; a parameter so a test owns the clock.
    @MainActor
    public static func capture(
        name: String,
        toolLibrary: AppToolLibraryPresenter,
        ledger: AppLedgerPresenter,
        units: DisplayUnitSelection,
        now: Date = Date()
    ) -> JobTemplate {
        let shown = ledger.tableArrangement?.read() ?? ledger.columns
        return JobTemplate(
            name: name,
            createdAt: now,
            presets: toolLibrary.presets,
            subjects: subjects(from: toolLibrary.presets),
            columnPreferences: shown.map {
                JobTemplateColumnPreference(columnID: $0.id.rawValue, visible: $0.visible)
            },
            units: JobTemplateUnits(selection: units)
        )
    }

    /// The subject vocabulary of a preset library: every distinct non-empty default subject,
    /// in first-appearance order, each with the colour of the first preset that names it.
    ///
    /// First-appearance rather than alphabetical because the library's order is the
    /// estimator's order, and first-preset colour because a subject drawn in two colours is
    /// already ambiguous in the rig — the template records the rig, it does not adjudicate it.
    public static func subjects(from presets: [ToolPresetSummary]) -> [JobTemplateSubject] {
        var seen = Set<String>()
        var result: [JobTemplateSubject] = []
        for preset in presets {
            let subject = preset.defaultSubject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, seen.insert(subject).inserted else { continue }
            result.append(JobTemplateSubject(name: subject, colorRGBA: preset.colorRGBA))
        }
        return result
    }

    // MARK: - Apply

    /// What applying a template did, and what is left for the caller.
    ///
    /// The units and subjects are *returned rather than installed* because their homes — the
    /// status bar's unit selection, the app tier's subject suggestions — live above this
    /// package. A receipt that names them is a contract the app tier can be tested against;
    /// an applier that silently reached up would be wiring nobody can see.
    public struct Receipt: Hashable, Sendable {

        /// How many presets the template installed.
        public var appliedPresetCount: Int
        /// The column identifiers that were found and re-ordered/shown/hidden.
        public var appliedColumnIDs: [String]
        /// Preferences for columns this project does not have. Reported, never invented:
        /// a template cannot create a column, only arrange the ones that exist.
        public var unknownColumnIDs: [String]
        /// The display units the caller installs where units live.
        public var units: DisplayUnitSelection
        /// The subject vocabulary the caller offers where subjects are suggested.
        public var subjects: [JobTemplateSubject]

        /// Creates a receipt.
        public init(
            appliedPresetCount: Int,
            appliedColumnIDs: [String],
            unknownColumnIDs: [String],
            units: DisplayUnitSelection,
            subjects: [JobTemplateSubject]
        ) {
            self.appliedPresetCount = appliedPresetCount
            self.appliedColumnIDs = appliedColumnIDs
            self.unknownColumnIDs = unknownColumnIDs
            self.units = units
            self.subjects = subjects
        }
    }

    /// Applies a template to a project's presenters, reproducing the rig.
    ///
    /// The preset library is **replaced**, which is what "start the next project from it"
    /// means for an empty project — the caller decides whether to offer a merge first.
    /// `onPresetsChanged` is invoked so the persistence hook the app installed writes the
    /// new library the same way an edit in the panel would.
    @MainActor
    @discardableResult
    public static func apply(
        _ template: JobTemplate,
        toolLibrary: AppToolLibraryPresenter,
        ledger: AppLedgerPresenter
    ) -> Receipt {
        toolLibrary.setPresets(template.presets)
        toolLibrary.onPresetsChanged?(template.presets)
        let (applied, unknown) = applyColumnPreferences(template.columnPreferences, to: ledger)
        return Receipt(
            appliedPresetCount: template.presets.count,
            appliedColumnIDs: applied,
            unknownColumnIDs: unknown,
            units: template.units.selection,
            subjects: template.subjects
        )
    }

    /// Applies column visibility and order to the ledger's **table**, so a template does exactly
    /// what a person dragging headers could have done and nothing more.
    ///
    /// Through ``AppLedgerPresenter/tableArrangement`` when a table shows the ledger (W-029). The
    /// presenter's `moveColumn`/`setColumnVisible` this used alone reached neither the table —
    /// which lays built-in columns out in its default and keeps the person's arrangement itself —
    /// nor the next refresh, which resets the presenter's columns from the projection; the
    /// receipt still listed every column as applied. Without a table (a headless core) the
    /// presenter's columns are all there is, and they are arranged instead.
    @MainActor
    static func applyColumnPreferences(
        _ preferences: [JobTemplateColumnPreference],
        to ledger: AppLedgerPresenter
    ) -> (applied: [String], unknown: [String]) {
        let current = ledger.tableArrangement?.read() ?? ledger.columns
        let known = Set(current.map(\.id))
        var applied: [String] = []
        var unknown: [String] = []
        var placed = Set<LedgerColumnID>()
        for preference in preferences {
            let columnID = LedgerColumnID(rawValue: preference.columnID)
            // A repeated id is placed once, as the pure form places it. Without this a hand-edited
            // file's [A, A, B] ended as [A, C, B] with A reported applied twice (BH-465).
            guard !placed.contains(columnID) else { continue }
            guard known.contains(columnID) else {
                unknown.append(preference.columnID)
                continue
            }
            placed.insert(columnID)
            applied.append(preference.columnID)
        }
        if let table = ledger.tableArrangement {
            table.apply(columns(applying: preferences, to: current))
        } else {
            for (position, id) in applied.enumerated() {
                let columnID = LedgerColumnID(rawValue: id)
                guard let preference = preferences.first(where: { $0.columnID == id }) else { continue }
                ledger.moveColumn(columnID, to: position)
                ledger.setColumnVisible(preference.visible, columnID: columnID)
            }
        }
        return (applied, unknown)
    }

    /// The pure form of the column rule, for callers that hold an array rather than a
    /// presenter: the preferred columns first, in preference order, with their visibility
    /// applied; columns the template does not name keep their relative order after them.
    public static func columns(
        applying preferences: [JobTemplateColumnPreference],
        to columns: [LedgerColumn]
    ) -> [LedgerColumn] {
        var byID: [LedgerColumnID: LedgerColumn] = [:]
        for column in columns { byID[column.id] = column }
        var arranged: [LedgerColumn] = []
        var placed = Set<LedgerColumnID>()
        for preference in preferences {
            let columnID = LedgerColumnID(rawValue: preference.columnID)
            guard var column = byID[columnID], placed.insert(columnID).inserted else { continue }
            column.visible = preference.visible
            arranged.append(column)
        }
        for column in columns where !placed.contains(column.id) {
            arranged.append(column)
        }
        return arranged
    }
}
