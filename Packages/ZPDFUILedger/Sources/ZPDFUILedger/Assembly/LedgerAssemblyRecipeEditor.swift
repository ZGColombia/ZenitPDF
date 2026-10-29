import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The assembly recipe editor (NL-QTY-07-UI): create, edit, duplicate and delete recipes, each
/// line an output subject, a formula over the measurement and the recipe's inputs, a unit and an
/// optional unit cost in the ledger's currency. Reached from the Apply Assembly panel with
/// New Recipe… and Edit Recipe…; it replaces the panel's content, so it opens no window or
/// sheet of its own.
///
/// Every check is the presenter's: the draft is validated exactly as a recipe file is on import,
/// and each formula by the formula engine the ledger runs. This model only keeps the typing.
@MainActor
@Observable
public final class LedgerAssemblyRecipeEditorModel {

    // MARK: - Editable rows

    /// The unit a line produces or an input carries.
    public enum Unit: String, CaseIterable, Hashable, Sendable, Identifiable {
        case count, length, area, volume

        public var id: String { rawValue }

        public var dimension: QuantityDimension {
            switch self {
            case .count: .count
            case .length: .length
            case .area: .area
            case .volume: .volume
            }
        }

        /// The unit a dimension is edited as; anything dimensionless is a count.
        public init(dimension: QuantityDimension) {
            switch dimension.lengthPower {
            case 1: self = .length
            case 2: self = .area
            case 3: self = .volume
            default: self = .count
            }
        }

        /// The base unit a value of this kind is in: what a unit cost is per.
        public var symbol: String {
            switch self {
            case .count: NSLocalizedString("pcs", comment: "Assembly recipe editor: the unit of a count, as in SEK per pcs")
            case .length: "m"
            case .area: "m²"
            case .volume: "m³"
            }
        }

        public var title: String {
            switch self {
            case .count: NSLocalizedString("Count (pcs)", comment: "Assembly recipe editor unit choice")
            case .length: NSLocalizedString("Length (m)", comment: "Assembly recipe editor unit choice")
            case .area: NSLocalizedString("Area (m²)", comment: "Assembly recipe editor unit choice")
            case .volume: NSLocalizedString("Volume (m³)", comment: "Assembly recipe editor unit choice")
            }
        }
    }

    /// One input as typed.
    public struct InputRow: Hashable, Identifiable {
        public let id: UUID
        public var name: String
        public var unit: Unit
        public var note: String

        public init(id: UUID = UUID(), name: String, unit: Unit, note: String = "") {
            self.id = id
            self.name = name
            self.unit = unit
            self.note = note
        }
    }

    /// One line as typed.
    public struct LineRow: Hashable, Identifiable {
        public let id: UUID
        /// The output subject — the derived row's name in the ledger.
        public var name: String
        public var formula: String
        public var unit: Unit
        /// The unit cost as typed, in the locale; empty for none.
        public var unitCostText: String
        /// The currency a stored unit cost was saved in; `nil` for the ledger's own.
        public var currencyCode: String?
        public var note: String

        public init(
            id: UUID = UUID(),
            name: String,
            formula: String,
            unit: Unit,
            unitCostText: String = "",
            currencyCode: String? = nil,
            note: String = ""
        ) {
            self.id = id
            self.name = name
            self.formula = formula
            self.unit = unit
            self.unitCostText = unitCostText
            self.currencyCode = currencyCode
            self.note = note
        }
    }

    /// The recipe being edited.
    public struct Form: Hashable {
        public var id: UUID
        public var name: String
        public var note: String
        public var inputs: [InputRow]
        public var lines: [LineRow]
    }

    // MARK: - State

    /// Every recipe, as the presenter lists them.
    public private(set) var entries: [LedgerAssemblyRecipeEntry]
    /// The recipe being edited, or `nil` when none is chosen.
    public var form: Form?
    /// Where the edited recipe lives; `nil` while it is new and unsaved.
    public private(set) var store: LedgerAssemblyRecipeStore?
    /// Where a new recipe will be saved.
    public var destination: LedgerAssemblyRecipeStore
    /// Waiting for the second press of Delete.
    public private(set) var isConfirmingDelete = false
    /// The outcome of the last save or delete, or a reason nothing happened.
    public private(set) var message: String?
    /// Whether ``message`` reports a refusal.
    public private(set) var lastFailed = false
    /// Whether a save or delete is in flight.
    public private(set) var isSaving = false

    /// The form as it was last loaded or saved — what Revert returns to.
    @ObservationIgnored private var baseline: Form?
    @ObservationIgnored private let presenter: any LedgerAssemblyRecipeEditing
    @ObservationIgnored private let locale: Locale

    /// Where a recipe can be saved here, in menu order.
    public var stores: [LedgerAssemblyRecipeStore] { presenter.assemblyRecipeStores }
    /// The currency a new unit cost is typed in.
    public var currencyCode: String { presenter.assemblyRecipeCurrencyCode }

    public init(presenter: any LedgerAssemblyRecipeEditing, locale: Locale = .autoupdatingCurrent) {
        self.presenter = presenter
        self.locale = locale
        self.entries = presenter.assemblyRecipes
        self.destination = presenter.assemblyRecipeStores.first ?? .project
    }

    // MARK: - Reading the form

    /// The entry being edited, when it is saved somewhere.
    public var entry: LedgerAssemblyRecipeEntry? {
        guard let form, store != nil else { return nil }
        return entries.first { $0.id == form.id }
    }

    /// A built-in recipe: shown, never changed.
    public var isReadOnly: Bool { store == .builtIn }
    /// A recipe that has not been saved yet.
    public var isNew: Bool { form != nil && store == nil }
    /// Whether the form differs from what was loaded or saved.
    public var hasUnsavedChanges: Bool { form != nil && (isNew || form != baseline) }

    /// Lines whose unit cost text is not a number.
    public var invalidUnitCosts: Set<UUID> {
        Set((form?.lines ?? []).compactMap { line in
            let text = line.unitCostText.trimmingCharacters(in: .whitespaces)
            return !text.isEmpty && LedgerNumberParsing.decimal(from: text) == nil ? line.id : nil
        })
    }

    /// The draft the form describes, for the presenter.
    public var draft: LedgerAssemblyRecipeDraft? {
        guard let form else { return nil }
        return LedgerAssemblyRecipeDraft(
            id: form.id,
            name: form.name,
            note: form.note,
            inputs: form.inputs.map { .init(name: $0.name, dimension: $0.unit.dimension, note: $0.note) },
            lines: form.lines.map { line in
                let text = line.unitCostText.trimmingCharacters(in: .whitespaces)
                let cost = text.isEmpty ? nil : LedgerNumberParsing.decimal(from: text).map {
                    DecimalQuantity(value: $0, dimension: .currency(line.currencyCode ?? currencyCode))
                }
                return .init(name: line.name, formula: line.formula, dimension: line.unit.dimension, unitCost: cost, note: line.note)
            }
        )
    }

    /// The presenter's verdict on the form: the importer's refusal and each line's formula.
    public var check: LedgerAssemblyRecipeCheck {
        draft.map { presenter.checkAssemblyRecipe($0) } ?? .valid
    }

    /// Where the edited recipe will be written by Save.
    public var saveStore: LedgerAssemblyRecipeStore { store ?? destination }

    public var canSave: Bool {
        form != nil && !isReadOnly && hasUnsavedChanges && !isSaving
            && stores.contains(saveStore) && invalidUnitCosts.isEmpty && check.isValid
    }

    public var canDelete: Bool {
        guard let store, store != .builtIn, !isSaving else { return false }
        return stores.contains(store)
    }

    /// What a unit cost on `line` is per, in words: "SEK per m²".
    public func unitCostLabel(_ line: LineRow) -> String {
        String(format: NSLocalizedString(
            "%1$@ per %2$@", comment: "Assembly recipe editor: a unit cost's unit; currency code, then the base unit"
        ), line.currencyCode ?? currencyCode, line.unit.symbol)
    }

    // MARK: - Choosing

    /// Loads the recipe `id` into the form. Refused, with a word, while the form has unsaved
    /// changes — Save or Revert first; nothing typed is thrown away silently.
    @discardableResult
    public func select(_ id: UUID) -> Bool {
        guard id != form?.id || isNew else { return true }
        guard !hasUnsavedChanges else {
            say(String(format: NSLocalizedString(
                "Save or revert the changes to “%@” first.",
                comment: "Assembly recipe editor: switching recipes with unsaved edits"
            ), form?.name ?? ""), failed: true)
            return false
        }
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        load(entry.draft, store: entry.store)
        message = nil
        return true
    }

    /// Starts a new recipe: one measured input, one line reading it.
    public func newRecipe() {
        guard guardUnsaved() else { return }
        let form = Form(
            id: UUID(),
            name: NSLocalizedString("New Recipe", comment: "Assembly recipe editor: the name a new recipe starts with"),
            note: "",
            inputs: [InputRow(name: "Length", unit: .length)],
            lines: [LineRow(name: "", formula: "Length", unit: .length)]
        )
        start(form)
    }

    /// Starts a new recipe as a copy of the one being edited — the way to change a built-in.
    public func duplicate() {
        guard var copy = form, guardUnsaved() || isReadOnly else { return }
        copy.id = UUID()
        copy.name = String(format: NSLocalizedString(
            "%@ copy", comment: "Assembly recipe editor: the name of a duplicated recipe"
        ), copy.name)
        copy.inputs = copy.inputs.map { InputRow(name: $0.name, unit: $0.unit, note: $0.note) }
        copy.lines = copy.lines.map {
            LineRow(name: $0.name, formula: $0.formula, unit: $0.unit, unitCostText: $0.unitCostText,
                    currencyCode: $0.currencyCode, note: $0.note)
        }
        start(copy)
    }

    /// Returns the form to what was loaded or saved; a new, unsaved recipe is dropped.
    public func revert() {
        if isNew {
            form = nil
        } else {
            form = baseline
        }
        isConfirmingDelete = false
        message = nil
    }

    // MARK: - Editing rows

    public func addInput() {
        form?.inputs.append(InputRow(name: "", unit: .length))
    }

    public func removeInput(_ id: UUID) {
        form?.inputs.removeAll { $0.id == id }
    }

    public func addLine() {
        form?.lines.append(LineRow(name: "", formula: "", unit: .count))
    }

    public func removeLine(_ id: UUID) {
        form?.lines.removeAll { $0.id == id }
    }

    // MARK: - Saving and deleting

    /// Saves the form where it lives, or to ``destination`` when it is new.
    @discardableResult
    public func save() async -> Bool {
        guard canSave, let draft else { return false }
        let target = saveStore
        isSaving = true
        defer { isSaving = false }
        let receipt = await presenter.saveAssemblyRecipe(draft, to: target)
        entries = presenter.assemblyRecipes
        if let failure = receipt.failureDescription {
            say(failure, failed: true)
            return false
        }
        if let saved = entries.first(where: { $0.id == draft.id }) {
            load(saved.draft, store: saved.store)
        }
        say(Self.savedMessage(name: draft.name, store: target, receipt: receipt), failed: false)
        return true
    }

    /// The first press of Delete: asks for the second.
    public func requestDelete() {
        guard canDelete else { return }
        isConfirmingDelete = true
        message = nil
    }

    public func cancelDelete() { isConfirmingDelete = false }

    /// The second press: deletes the recipe from where it lives.
    @discardableResult
    public func confirmDelete() async -> Bool {
        guard isConfirmingDelete, canDelete, let form, let store else { return false }
        isConfirmingDelete = false
        isSaving = true
        defer { isSaving = false }
        let receipt = await presenter.deleteAssemblyRecipe(form.id, from: store)
        entries = presenter.assemblyRecipes
        if let failure = receipt.failureDescription {
            say(failure, failed: true)
            return false
        }
        let name = form.name
        self.form = nil
        self.store = nil
        baseline = nil
        say(String(format: NSLocalizedString(
            "Deleted “%@”. Rows that already use it keep their copy of the recipe.",
            comment: "Assembly recipe editor: a recipe was deleted"
        ), name), failed: false)
        return true
    }

    // MARK: - Words

    public static func storeTitle(_ store: LedgerAssemblyRecipeStore) -> String {
        switch store {
        case .builtIn: NSLocalizedString("Built-in", comment: "Assembly recipe editor: recipes shipped with the app")
        case .office: NSLocalizedString("Office Library", comment: "Assembly recipe editor: the office recipe library")
        case .project: NSLocalizedString("This Project", comment: "Assembly recipe editor: recipes saved in the project")
        }
    }

    static func savedMessage(name: String, store: LedgerAssemblyRecipeStore, receipt: LedgerAssemblyRecipeReceipt) -> String {
        var text = String(format: NSLocalizedString(
            "Saved “%1$@” in %2$@.", comment: "Assembly recipe editor: saved; recipe name, then where"
        ), name.trimmingCharacters(in: .whitespacesAndNewlines), storeTitle(store))
        if receipt.updatedRowCount > 0 {
            text += " " + LedgerPlurals.measuredRowsUpdated(receipt.updatedRowCount)
        }
        if receipt.lockedRowCount > 0 {
            text += " " + LedgerPlurals.lockedRowsKept(receipt.lockedRowCount)
        }
        return text
    }

    // MARK: - Private

    private func load(_ draft: LedgerAssemblyRecipeDraft, store: LedgerAssemblyRecipeStore) {
        let form = Form(
            id: draft.id,
            name: draft.name,
            note: draft.note,
            inputs: draft.inputs.map { InputRow(name: $0.name, unit: Unit(dimension: $0.dimension), note: $0.note) },
            lines: draft.lines.map { line in
                LineRow(
                    name: line.name,
                    formula: line.formula,
                    unit: Unit(dimension: line.dimension),
                    unitCostText: line.unitCost.map { LedgerNumberParsing.editingString($0.value, locale: locale) } ?? "",
                    currencyCode: line.unitCost?.dimension.currencyCode,
                    note: line.note
                )
            }
        )
        self.form = form
        self.baseline = form
        self.store = store
        isConfirmingDelete = false
    }

    private func start(_ form: Form) {
        self.form = form
        self.baseline = nil
        self.store = nil
        if !stores.contains(destination), let first = stores.first { destination = first }
        isConfirmingDelete = false
        message = nil
    }

    /// `true` when there is nothing unsaved to lose; otherwise says so and returns `false`.
    private func guardUnsaved() -> Bool {
        guard hasUnsavedChanges, !isReadOnly else { return true }
        say(String(format: NSLocalizedString(
            "Save or revert the changes to “%@” first.",
            comment: "Assembly recipe editor: switching recipes with unsaved edits"
        ), form?.name ?? ""), failed: true)
        return false
    }

    private func say(_ text: String, failed: Bool) {
        message = text
        lastFailed = failed
    }
}

// MARK: - View

/// The recipe editor's view: the recipe list on the left, the chosen recipe on the right.
public struct LedgerAssemblyRecipeEditor: View {

    @Bindable private var model: LedgerAssemblyRecipeEditorModel
    private let onDone: () -> Void

    public init(model: LedgerAssemblyRecipeEditorModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Assembly Recipes", comment: "Title of the assembly recipe editor"),
                subtitle: NSLocalizedString(
                    "A recipe turns one measured row into several quantities.",
                    comment: "Assembly recipe editor subtitle"
                ),
                count: model.entries.count
            )
            HStack(alignment: .top, spacing: 0) {
                recipeList
                    .frame(width: 210)
                ZPDFHairlineDivider(axis: .vertical)
                ScrollView {
                    recipeForm
                        .padding(ZPDFSpacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ZPDFHairlineDivider()
            footer
                .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Assembly Recipes", comment: "Title of the assembly recipe editor"))
    }

    // MARK: List

    private var recipeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(LedgerAssemblyRecipeStore.allCases, id: \.self) { store in
                    let recipes = model.entries.filter { $0.store == store }
                    if !recipes.isEmpty {
                        Section(LedgerAssemblyRecipeEditorModel.storeTitle(store)) {
                            ForEach(recipes) { entry in
                                recipeRow(entry)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel(NSLocalizedString("Recipes", comment: "Assembly recipe editor: the recipe list"))
            ZPDFHairlineDivider()
            HStack(spacing: ZPDFSpacing.s) {
                Button(NSLocalizedString("New", comment: "Assembly recipe editor: start a new recipe")) { model.newRecipe() }
                    .accessibilityLabel(NSLocalizedString("New Recipe", comment: "Assembly recipe editor: start a new recipe"))
                Button(NSLocalizedString("Duplicate", comment: "Assembly recipe editor: copy the chosen recipe")) { model.duplicate() }
                    .disabled(model.form == nil || model.isNew)
                Spacer(minLength: 0)
            }
            .padding(ZPDFSpacing.m)
        }
    }

    private func recipeRow(_ entry: LedgerAssemblyRecipeEntry) -> some View {
        let isCurrent = model.form?.id == entry.id && !model.isNew
        return Button {
            model.select(entry.id)
        } label: {
            HStack(spacing: ZPDFSpacing.xs) {
                Text(entry.draft.name).zpdfText(.control, .textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if entry.isReadOnly {
                    Image(systemName: "lock")
                        .imageScale(.small)
                        .foregroundStyle(ZPDFColor.color(.textSecondary))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? ZPDFColor.color(.selection) : Color.clear)
        .accessibilityLabel(entry.isReadOnly
            ? String(format: NSLocalizedString("%@, built-in, read-only", comment: "Assembly recipe editor: a built-in recipe in the list"), entry.draft.name)
            : entry.draft.name)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    // MARK: Form

    @ViewBuilder
    private var recipeForm: some View {
        if model.form != nil {
            let check = model.check
            VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                if model.isReadOnly {
                    ZPDFInlineWarning(
                        severity: .info,
                        message: NSLocalizedString(
                            "Built-in recipes cannot be changed. Duplicate this one to make your own.",
                            comment: "Assembly recipe editor: a built-in recipe is shown"
                        ),
                        actionTitle: NSLocalizedString("Duplicate", comment: "Assembly recipe editor: copy the chosen recipe"),
                        action: { model.duplicate() }
                    )
                }
                Group {
                    ZPDFInspectorRow(label: NSLocalizedString("Name", comment: "Assembly recipe editor: the recipe's name")) {
                        TextField("", text: formBinding(\.name))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(NSLocalizedString("Recipe name", comment: "Assembly recipe editor: the recipe's name"))
                    }
                    ZPDFInspectorRow(label: NSLocalizedString("Note", comment: "Assembly recipe editor: free text about the recipe")) {
                        TextField(NSLocalizedString("Optional", comment: "Assembly recipe editor: an optional field"), text: formBinding(\.note))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(NSLocalizedString("Recipe note", comment: "Assembly recipe editor: free text about the recipe"))
                    }
                    storeRow
                }
                .disabled(model.isReadOnly)

                sectionTitle(NSLocalizedString("Inputs", comment: "Assembly recipe editor: the values a recipe reads"))
                Text(NSLocalizedString(
                    "Length, Area, Perimeter and Height come from the measured row; any other name is typed when the recipe is applied.",
                    comment: "Assembly recipe editor: how inputs are filled"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array((model.form?.inputs ?? []).enumerated()), id: \.element.id) { index, input in
                    inputRow(input, measured: check.measuredInputs.contains(index))
                }
                Button(NSLocalizedString("Add Input", comment: "Assembly recipe editor: add an input")) { model.addInput() }
                    .disabled(model.isReadOnly)

                sectionTitle(NSLocalizedString("Lines", comment: "Assembly recipe editor: the quantities a recipe produces"))
                Text(String(format: NSLocalizedString(
                    "Each line becomes a derived row under the measured row. A unit cost is in %@ per unit of the line and prices the row: Total Cost = quantity × unit cost.",
                    comment: "Assembly recipe editor: what a line is; the placeholder is the currency"
                ), model.currencyCode))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array((model.form?.lines ?? []).enumerated()), id: \.element.id) { index, line in
                    lineRow(line, problem: check.lineProblems[index])
                }
                Button(NSLocalizedString("Add Line", comment: "Assembly recipe editor: add a line")) { model.addLine() }
                    .disabled(model.isReadOnly)

                if let refusal = check.refusal, !model.isReadOnly {
                    ZPDFInlineWarning(severity: .warning, message: refusal)
                }
            }
        } else {
            ZPDFEmptyState(
                glyph: .symbol(.quantityLedger),
                title: NSLocalizedString("No recipe chosen", comment: "Assembly recipe editor: nothing is being edited"),
                message: NSLocalizedString(
                    "Choose a recipe on the left, or press New to write one.",
                    comment: "Assembly recipe editor: nothing is being edited"
                )
            )
        }
    }

    @ViewBuilder
    private var storeRow: some View {
        ZPDFInspectorRow(label: NSLocalizedString("Saved in", comment: "Assembly recipe editor: where the recipe lives")) {
            if model.isNew {
                Picker("", selection: $model.destination) {
                    ForEach(model.stores, id: \.self) { store in
                        Text(LedgerAssemblyRecipeEditorModel.storeTitle(store)).tag(store)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Save the recipe in", comment: "Assembly recipe editor: where a new recipe is saved"))
            } else if let store = model.store {
                Text(LedgerAssemblyRecipeEditorModel.storeTitle(store)).zpdfText(.control, .textSecondary)
            }
        }
    }

    private func inputRow(_ input: LedgerAssemblyRecipeEditorModel.InputRow, measured: Bool) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            TextField(NSLocalizedString("Name", comment: "Assembly recipe editor: an input's name"), text: inputBinding(input.id, \.name))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityLabel(NSLocalizedString("Input name", comment: "Assembly recipe editor: an input's name"))
            Picker("", selection: inputBinding(input.id, \.unit)) {
                ForEach(LedgerAssemblyRecipeEditorModel.Unit.allCases) { unit in Text(unit.title).tag(unit) }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel(String(format: NSLocalizedString("Unit of %@", comment: "Assembly recipe editor: an input's unit; the input's name"), input.name))
            Text(measured
                 ? NSLocalizedString("From the measurement", comment: "Assembly recipe editor: an input a measurement supplies")
                 : NSLocalizedString("Typed when applied", comment: "Assembly recipe editor: an input the estimator types"))
                .zpdfText(.caption, .textSecondary)
            Spacer(minLength: 0)
            removeButton(
                label: String(format: NSLocalizedString("Remove input %@", comment: "Assembly recipe editor: remove an input; its name"), input.name)
            ) { model.removeInput(input.id) }
        }
        .disabled(model.isReadOnly)
    }

    private func lineRow(_ line: LedgerAssemblyRecipeEditorModel.LineRow, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.s) {
                TextField(NSLocalizedString("Output subject", comment: "Assembly recipe editor: a line's name, the derived row's subject"),
                          text: lineBinding(line.id, \.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .accessibilityLabel(NSLocalizedString("Output subject", comment: "Assembly recipe editor: a line's name, the derived row's subject"))
                TextField(NSLocalizedString("Formula", comment: "Assembly recipe editor: a line's formula"), text: lineBinding(line.id, \.formula))
                    .textFieldStyle(.roundedBorder)
                    .font(ZPDFTypography.font(.code))
                    .accessibilityLabel(String(format: NSLocalizedString("Formula for %@", comment: "Assembly recipe editor: a line's formula; the line's name"), line.name))
                Picker("", selection: lineBinding(line.id, \.unit)) {
                    ForEach(LedgerAssemblyRecipeEditorModel.Unit.allCases) { unit in Text(unit.title).tag(unit) }
                }
                .labelsHidden()
                .frame(width: 130)
                .accessibilityLabel(String(format: NSLocalizedString("Unit of %@", comment: "Assembly recipe editor: a line's unit; the line's name"), line.name))
                removeButton(
                    label: String(format: NSLocalizedString("Remove line %@", comment: "Assembly recipe editor: remove a line; its name"), line.name)
                ) { model.removeLine(line.id) }
            }
            HStack(spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString("Unit cost", comment: "Assembly recipe editor: a line's rate"))
                    .zpdfText(.caption, .textSecondary)
                TextField(NSLocalizedString("None", comment: "Assembly recipe editor: no unit cost"), text: lineBinding(line.id, \.unitCostText))
                    .textFieldStyle(.roundedBorder)
                    .font(ZPDFTypography.font(.monoNumeric))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .accessibilityLabel(String(format: NSLocalizedString(
                        "Unit cost of %1$@, %2$@", comment: "Assembly recipe editor: a line's rate; line name, then its unit"
                    ), line.name, model.unitCostLabel(line)))
                Text(model.unitCostLabel(line)).zpdfText(.caption, .textSecondary)
                Spacer(minLength: 0)
            }
            if model.invalidUnitCosts.contains(line.id) {
                Text(NSLocalizedString("The unit cost is not a number.", comment: "Assembly recipe editor: a unit cost that does not parse"))
                    .zpdfText(.caption, .textPrimary)
            }
            if let problem, !model.isReadOnly {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .zpdfText(.caption, .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(format: NSLocalizedString(
                        "Problem in %1$@: %2$@", comment: "Assembly recipe editor: a line's formula problem; line name, then the problem"
                    ), line.name, problem))
            }
        }
        .padding(.vertical, ZPDFSpacing.xs)
        .disabled(model.isReadOnly)
    }

    private func removeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .zpdfText(.sectionHeader, .textPrimary)
            .padding(.top, ZPDFSpacing.s)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.m) {
            if let message = model.message {
                Text(message)
                    .zpdfText(.caption, model.lastFailed ? .textPrimary : .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            Spacer()
            if model.isConfirmingDelete {
                Text(String(format: NSLocalizedString(
                    "Delete “%@”?", comment: "Assembly recipe editor: confirm a delete; the recipe's name"
                ), model.form?.name ?? ""))
                .zpdfText(.caption, .textPrimary)
                Button(NSLocalizedString("Cancel", comment: "Assembly recipe editor: keep the recipe")) { model.cancelDelete() }
                Button(NSLocalizedString("Delete", comment: "Assembly recipe editor: delete the recipe, second press")) {
                    Task { await model.confirmDelete() }
                }
            } else {
                Button(NSLocalizedString("Delete…", comment: "Assembly recipe editor: delete the recipe, first press")) { model.requestDelete() }
                    .disabled(!model.canDelete)
            }
            Button(NSLocalizedString("Revert", comment: "Assembly recipe editor: throw away unsaved edits")) { model.revert() }
                .disabled(!model.hasUnsavedChanges || model.isReadOnly)
            Button(NSLocalizedString("Done", comment: "Assembly recipe editor: back to Apply Assembly")) { onDone() }
                .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Save", comment: "Assembly recipe editor: save the recipe")) {
                Task { await model.save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
    }

    // MARK: Bindings

    private func formBinding(_ keyPath: WritableKeyPath<LedgerAssemblyRecipeEditorModel.Form, String>) -> Binding<String> {
        Binding(
            get: { model.form?[keyPath: keyPath] ?? "" },
            set: { model.form?[keyPath: keyPath] = $0 }
        )
    }

    private func inputBinding<Value>(
        _ id: UUID, _ keyPath: WritableKeyPath<LedgerAssemblyRecipeEditorModel.InputRow, Value>
    ) -> Binding<Value> where Value: Hashable {
        Binding(
            get: {
                guard let row = model.form?.inputs.first(where: { $0.id == id }) else {
                    return LedgerAssemblyRecipeEditorModel.InputRow(name: "", unit: .count)[keyPath: keyPath]
                }
                return row[keyPath: keyPath]
            },
            set: { value in
                guard let index = model.form?.inputs.firstIndex(where: { $0.id == id }) else { return }
                model.form?.inputs[index][keyPath: keyPath] = value
            }
        )
    }

    private func lineBinding<Value>(
        _ id: UUID, _ keyPath: WritableKeyPath<LedgerAssemblyRecipeEditorModel.LineRow, Value>
    ) -> Binding<Value> where Value: Hashable {
        Binding(
            get: {
                guard let row = model.form?.lines.first(where: { $0.id == id }) else {
                    return LedgerAssemblyRecipeEditorModel.LineRow(name: "", formula: "", unit: .count)[keyPath: keyPath]
                }
                return row[keyPath: keyPath]
            },
            set: { value in
                guard let index = model.form?.lines.firstIndex(where: { $0.id == id }) else { return }
                model.form?.lines[index][keyPath: keyPath] = value
            }
        )
    }
}
