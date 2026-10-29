import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Applying an assembly to the selected measurements (NL-QTY-07, ADR-0024): pick a recipe, give
/// the values the measurements do not carry, apply — one undoable step. The derived rows then
/// appear under each measured row with ƒ, and follow it.
@MainActor
@Observable
public final class LedgerAssemblyPanelModel {

    /// The recipes on offer — the built-in ones and the office library's.
    public private(set) var assemblies: [LedgerAssemblySummary]
    /// Imports a `.zpdfassembly` file into the office library (the app owns the open panel) and
    /// answers the recipes now on offer, or `nil` when nothing was imported. `nil` hides the button.
    @ObservationIgnored public var importRecipes: (@MainActor () async -> [LedgerAssemblySummary]?)?
    /// Saves the office library as a `.zpdfassembly` file to share. `nil` hides the button.
    @ObservationIgnored public var exportRecipes: (@MainActor () -> Void)?
    /// The rows the assembly is applied to.
    public let markupIDs: Set<UUID>
    /// The chosen recipe.
    public var selectedID: UUID?
    /// What was typed for each input, by name.
    public var parameterTexts: [String: String] = [:]
    /// The outcome of the last Apply or Remove.
    public private(set) var message: String?
    /// Whether the last Apply or Remove was refused.
    public private(set) var lastFailed = false
    /// Whether a change is in flight.
    public private(set) var isApplying = false

    @ObservationIgnored private let presenter: any LedgerAssemblyApplying
    @ObservationIgnored private let locale: Locale
    /// The unit a length input is typed in: the ledger's display length unit, as the Tool
    /// Library's Assembly row takes it (U-064).
    public let lengthUnit: LengthUnit

    public init(
        presenter: any LedgerAssemblyApplying,
        markupIDs: Set<UUID>,
        locale: Locale = .autoupdatingCurrent,
        lengthUnit: LengthUnit = .metre
    ) {
        self.presenter = presenter
        let offered = presenter.availableAssemblies
        self.assemblies = offered
        self.markupIDs = markupIDs
        self.selectedID = offered.first?.id
        self.locale = locale
        self.lengthUnit = lengthUnit
    }

    /// The chosen recipe.
    public var selected: LedgerAssemblySummary? { assemblies.first { $0.id == selectedID } }

    // MARK: Recipe editor (NL-QTY-07-UI)

    /// The open recipe editor, shown in place of the panel's content, or `nil`.
    public private(set) var recipeEditor: LedgerAssemblyRecipeEditorModel?

    /// Whether recipes can be written here — offers New Recipe… and Edit Recipe….
    public var canEditRecipes: Bool {
        guard let editing = presenter as? any LedgerAssemblyRecipeEditing else { return false }
        return !editing.assemblyRecipeStores.isEmpty
    }

    /// Opens the editor on a new recipe.
    public func openNewRecipe() {
        guard canEditRecipes, let editing = presenter as? any LedgerAssemblyRecipeEditing else { return }
        let editor = LedgerAssemblyRecipeEditorModel(presenter: editing, locale: locale)
        editor.newRecipe()
        recipeEditor = editor
    }

    /// Opens the editor on the chosen recipe; a built-in one opens read-only, to duplicate.
    public func openEditRecipe() {
        guard canEditRecipes, let editing = presenter as? any LedgerAssemblyRecipeEditing else { return }
        let editor = LedgerAssemblyRecipeEditorModel(presenter: editing, locale: locale)
        if let selectedID { editor.select(selectedID) }
        recipeEditor = editor
    }

    /// Back to Apply Assembly, offering the recipes as they now are.
    public func closeRecipeEditor() {
        let edited = recipeEditor?.form?.id
        recipeEditor = nil
        assemblies = presenter.availableAssemblies
        if let edited, assemblies.contains(where: { $0.id == edited }) {
            selectedID = edited
        } else if !assemblies.contains(where: { $0.id == selectedID }) {
            selectedID = assemblies.first?.id
        }
    }

    /// Runs the import and offers what it brought.
    public func importRecipeFile() async {
        guard let importRecipes, let updated = await importRecipes() else { return }
        let known = Set(assemblies.map(\.id))
        assemblies = updated
        if let added = updated.first(where: { !known.contains($0.id) }) { selectedID = added.id }
        message = NSLocalizedString("Recipes imported into the office library.", comment: "Assembly panel: a recipe file was imported")
        lastFailed = false
    }

    /// A typed value that is not a number, by input name — shown under the field.
    ///
    /// Only the chosen recipe's inputs count, as in ``parameters()`` and ``missingParameters``.
    /// Text left in a field of a recipe chosen earlier used to count too, so Apply stayed
    /// disabled with no hint on screen to say why (S-081).
    public var invalidInputs: Set<String> {
        Set(LedgerAssemblySummary.Input.unreadableInputs(
            selected?.inputs ?? [], texts: parameterTexts, parse: Self.parameterValue
        ))
    }

    /// A typed parameter as a number, read exactly as the preset editor's Assembly row reads
    /// it (`ToolPresetAssembly.quantity`: ``ZPDFDecimalParser`` with exponents), so the same
    /// text gives the same parameter in both places (S-076).
    nonisolated static func parameterValue(_ text: String) -> Decimal? {
        LedgerNumberParsing.decimal(from: text, allowingExponent: true)
    }

    /// The free parameters still empty — Apply needs every one. The rule the preset editor's
    /// Assembly row applies too (V-067).
    public var missingParameters: [String] {
        LedgerAssemblySummary.Input.missingParameters(selected?.inputs ?? [], texts: parameterTexts)
    }

    public var canApply: Bool {
        selected != nil && !markupIDs.isEmpty && missingParameters.isEmpty && invalidInputs.isEmpty && !isApplying
    }

    /// The hint under a parameter field whose text is not a number (W-066). An unreadable value
    /// disables Apply (``canApply``), so the hint says what to do, not Bulk Edit's "Nothing will
    /// change in this field", which contradicted the disabled button.
    public static var invalidNumberHint: String {
        NSLocalizedString(
            "Not a number. Correct it to apply the assembly.",
            comment: "Apply Assembly panel: hint under a parameter field whose text does not parse; Apply stays disabled until it is corrected"
        )
    }

    /// The typed values as quantities in SI base units.
    ///
    /// A length is typed in ``lengthUnit`` — the unit its field is labelled in. It used to be
    /// taken as metres whatever the project showed, so "200" was 200 m here and 0.2 m in the
    /// Tool Library's Assembly row in a millimetre project (U-064). Both now convert through
    /// the one rule, `LedgerAssemblySummary.Input.quantities` (V-067).
    func parameters() -> [String: DecimalQuantity] {
        LedgerAssemblySummary.Input.quantities(
            selected?.inputs ?? [], texts: parameterTexts, lengthUnit: lengthUnit, parse: Self.parameterValue
        )
    }

    /// Applies the chosen recipe to the rows.
    @discardableResult
    public func apply() async -> Bool {
        guard canApply, let id = selectedID else { return false }
        return await run(id)
    }

    /// Removes any assembly from the rows.
    @discardableResult
    public func remove() async -> Bool {
        await run(nil)
    }

    private func run(_ id: UUID?) async -> Bool {
        isApplying = true
        defer { isApplying = false }
        let receipt = await presenter.applyAssembly(id, parameters: id == nil ? [:] : parameters(), to: markupIDs)
        if let failure = receipt.failureDescription {
            message = failure
            lastFailed = true
            return false
        }
        lastFailed = false
        message = String(format: NSLocalizedString(
            "Done: %@. Undo takes it back.",
            comment: "Column Manager confirmation; the placeholder is the change's name"
        ), receipt.undoActionName)
        return true
    }

    /// The unit a value for `dimension` is typed in: the display length unit for a length, m²
    /// and m³ for an area and a volume — the labels the Tool Library's Assembly row shows.
    public func unitLabel(_ dimension: QuantityDimension) -> String {
        LedgerAssemblySummary.Input.unitLabel(for: dimension, lengthUnit: lengthUnit)
    }
}

/// The panel's view.
public struct LedgerAssemblyPanel: View {

    @Bindable private var model: LedgerAssemblyPanelModel
    private let onDone: () -> Void

    public init(model: LedgerAssemblyPanelModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        if let editor = model.recipeEditor {
            LedgerAssemblyRecipeEditor(model: editor) { model.closeRecipeEditor() }
        } else {
            applyContent
        }
    }

    private var applyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Apply Assembly", comment: "Title of the assembly panel"),
                subtitle: LedgerPlurals.selectedMeasurements(model.markupIDs.count),
                count: model.markupIDs.count
            )
            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    ZPDFInspectorRow(label: NSLocalizedString("Assembly", comment: "Assembly panel: recipe picker")) {
                        Picker("", selection: $model.selectedID) {
                            ForEach(model.assemblies) { assembly in
                                Text(assembly.name).tag(Optional(assembly.id))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(NSLocalizedString("Assembly", comment: "Assembly panel: recipe picker"))
                    }
                    if model.canEditRecipes {
                        HStack(spacing: ZPDFSpacing.m) {
                            Spacer(minLength: 0)
                            Button(NSLocalizedString("New Recipe…", comment: "Assembly panel: write a new assembly recipe")) {
                                model.openNewRecipe()
                            }
                            Button(NSLocalizedString("Edit Recipe…", comment: "Assembly panel: edit the chosen assembly recipe")) {
                                model.openEditRecipe()
                            }
                            .disabled(model.selected == nil)
                        }
                    }
                    if let selected = model.selected {
                        if let note = selected.note {
                            Text(note).zpdfText(.caption, .textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(selected.inputs, id: \.name) { input in
                            inputRow(input)
                        }
                        Text(NSLocalizedString("Produces", comment: "Assembly panel: the lines a recipe produces"))
                            .zpdfText(.caption, .textSecondary)
                        ForEach(selected.lines, id: \.name) { line in
                            HStack {
                                Text("ƒ " + line.name).zpdfText(.control, .textPrimary)
                                Spacer()
                                Text(line.formula).zpdfText(.caption, .textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(ZPDFSpacing.l)
            }
            ZPDFHairlineDivider()
            HStack(spacing: ZPDFSpacing.m) {
                if let message = model.message {
                    Text(message)
                        .zpdfText(.caption, model.lastFailed ? .textPrimary : .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
                Spacer()
                if model.importRecipes != nil {
                    Button(NSLocalizedString("Import Recipes…", comment: "Assembly panel: add recipes from a .zpdfassembly file to the office library")) {
                        Task { await model.importRecipeFile() }
                    }
                }
                if model.exportRecipes != nil {
                    Button(NSLocalizedString("Export Recipes…", comment: "Assembly panel: save the office library's recipes as a .zpdfassembly file")) {
                        model.exportRecipes?()
                    }
                }
                Button(NSLocalizedString("Remove Assembly", comment: "Assembly panel: remove any assembly from the rows")) {
                    Task { await model.remove() }
                }
                .disabled(model.isApplying)
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Apply", comment: "Column Manager: apply the column edit")) {
                    Task { await model.apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Apply Assembly", comment: "Title of the assembly panel"))
    }

    private func inputRow(_ input: LedgerAssemblySummary.Input) -> some View {
        let unit = model.unitLabel(input.dimension)
        let prompt = input.isFreeParameter
            ? NSLocalizedString("Required", comment: "Assembly panel: a value the estimator must type")
            : NSLocalizedString("From the measurement", comment: "Assembly panel: a value the measurement supplies when it has one")
        return VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFInspectorRow(label: input.name, helpText: input.note) {
                HStack(spacing: ZPDFSpacing.xs) {
                    TextField(prompt, text: Binding(
                        get: { model.parameterTexts[input.name] ?? "" },
                        set: { model.parameterTexts[input.name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(ZPDFTypography.font(.monoNumeric))
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(unit.isEmpty ? input.name : "\(input.name), \(unit)")
                    if !unit.isEmpty { Text(unit).zpdfText(.caption, .textSecondary) }
                }
            }
            if model.invalidInputs.contains(input.name) {
                // W-066: this panel's own words. It borrowed Bulk Edit's "Nothing will change
                // in this field", but here an unreadable number disables Apply for every row.
                Text(LedgerAssemblyPanelModel.invalidNumberHint)
                    .zpdfText(.caption, .textSecondary)
            }
        }
    }
}
