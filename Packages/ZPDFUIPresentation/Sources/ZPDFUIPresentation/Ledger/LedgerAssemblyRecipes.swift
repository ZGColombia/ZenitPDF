import Foundation

// MARK: - Assembly recipe authoring (NL-QTY-07-UI, ADR-0024)

/// Where an assembly recipe lives.
public enum LedgerAssemblyRecipeStore: String, CaseIterable, Hashable, Sendable {
    /// Shipped with the application. Never edited, never deleted — only duplicated.
    case builtIn
    /// The office library in Application Support, shared as `.zpdfassembly` files.
    case office
    /// Saved inside this project, travelling with its file.
    case project
}

/// One recipe as the editor edits it: plain values, no formula engine.
///
/// A draft is what the editor hands the presenter to check and to save. It is never evaluated
/// here; the presenter turns it into the recipe the ledger runs and validates it exactly as a
/// recipe file is validated on import.
public struct LedgerAssemblyRecipeDraft: Hashable, Sendable, Identifiable {

    /// One value the recipe expects from the measurement it is applied to.
    public struct Input: Hashable, Sendable {
        /// The name a formula writes (`Length`, `Height`, `Spacing`).
        public var name: String
        /// What a value of this input is.
        public var dimension: QuantityDimension
        /// Free text for the estimator.
        public var note: String

        public init(name: String, dimension: QuantityDimension, note: String = "") {
            self.name = name
            self.dimension = dimension
            self.note = note
        }
    }

    /// One quantity the recipe produces — one derived row per measured row.
    public struct Line: Hashable, Sendable {
        /// The output subject: what the derived row is called in the ledger.
        public var name: String
        /// The formula over the recipe's inputs, as typed.
        public var formula: String
        /// The unit the line produces: count, length, area or volume.
        public var dimension: QuantityDimension
        /// The rate per base unit of ``dimension`` (piece, m, m², m³), as money in one currency
        /// — the derived row's Unit Cost (ADR-0020). `nil` prices nothing.
        public var unitCost: DecimalQuantity?
        /// Free text for the estimator.
        public var note: String

        public init(
            name: String,
            formula: String,
            dimension: QuantityDimension,
            unitCost: DecimalQuantity? = nil,
            note: String = ""
        ) {
            self.name = name
            self.formula = formula
            self.dimension = dimension
            self.unitCost = unitCost
            self.note = note
        }
    }

    /// The recipe's stable identity. A new recipe gets a new one; editing keeps it.
    public var id: UUID
    public var name: String
    public var note: String
    public var inputs: [Input]
    public var lines: [Line]

    public init(id: UUID, name: String, note: String = "", inputs: [Input], lines: [Line]) {
        self.id = id
        self.name = name
        self.note = note
        self.inputs = inputs
        self.lines = lines
    }
}

/// A recipe on offer to the editor, with where it lives.
public struct LedgerAssemblyRecipeEntry: Hashable, Sendable, Identifiable {
    public let draft: LedgerAssemblyRecipeDraft
    public let store: LedgerAssemblyRecipeStore

    public var id: UUID { draft.id }
    /// Built-in recipes are read-only; duplicate one to change it.
    public var isReadOnly: Bool { store == .builtIn }

    public init(draft: LedgerAssemblyRecipeDraft, store: LedgerAssemblyRecipeStore) {
        self.draft = draft
        self.store = store
    }
}

/// What the presenter found wrong with a draft, without saving anything.
public struct LedgerAssemblyRecipeCheck: Hashable, Sendable {
    /// The refusal a recipe import would give this recipe, in words — or `nil`.
    public let refusal: String?
    /// Why a line's formula cannot be used, by line index.
    public let lineProblems: [Int: String]
    /// The inputs, by index, a measured row fills (`Length`, `Area`); every other input is
    /// typed when the recipe is applied.
    public let measuredInputs: Set<Int>

    public init(refusal: String? = nil, lineProblems: [Int: String] = [:], measuredInputs: Set<Int> = []) {
        self.refusal = refusal
        self.lineProblems = lineProblems
        self.measuredInputs = measuredInputs
    }

    /// Whether the draft can be saved.
    public var isValid: Bool { refusal == nil && lineProblems.isEmpty }

    public static let valid = LedgerAssemblyRecipeCheck()
}

/// What saving or deleting a recipe did.
public struct LedgerAssemblyRecipeReceipt: Hashable, Sendable {
    /// Why nothing was saved, or `nil`.
    public var failureDescription: String?
    /// Measured rows of this project that carried the recipe and now carry the saved one, as
    /// one undoable step — their derived rows follow at once.
    public var updatedRowCount: Int
    /// Rows that carry the recipe but are locked, left on the copy they had.
    public var lockedRowCount: Int

    public init(failureDescription: String? = nil, updatedRowCount: Int = 0, lockedRowCount: Int = 0) {
        self.failureDescription = failureDescription
        self.updatedRowCount = updatedRowCount
        self.lockedRowCount = lockedRowCount
    }

    public var didFail: Bool { failureDescription != nil }

    public static func failure(_ description: String) -> LedgerAssemblyRecipeReceipt {
        LedgerAssemblyRecipeReceipt(failureDescription: description)
    }
}

/// A ledger presenter whose assembly recipes can be authored in the app (NL-QTY-07-UI).
///
/// Reached by a conditional cast from the Apply Assembly panel's presenter, like every other
/// ledger capability: a presenter that cannot save recipes is not cast, and the panel offers
/// no New Recipe… or Edit Recipe….
@MainActor
public protocol LedgerAssemblyRecipeEditing: LedgerAssemblyApplying {
    /// Every recipe the editor lists: built-in (read-only), this project's, the office's.
    var assemblyRecipes: [LedgerAssemblyRecipeEntry] { get }
    /// Where a recipe can be saved here, in menu order. Empty: nothing can be saved.
    var assemblyRecipeStores: [LedgerAssemblyRecipeStore] { get }
    /// The currency a new unit cost is typed in: the ledger's own (ADR-0020 §2.5).
    var assemblyRecipeCurrencyCode: String { get }
    /// Checks a draft exactly as a recipe file is checked on import, and each line's formula
    /// with the formula engine. Changes nothing.
    func checkAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft) -> LedgerAssemblyRecipeCheck
    /// Saves a draft to `store`, replacing a recipe with the same id there, and brings the rows
    /// of this project that carry the recipe up to date as one undoable step. Refused whole,
    /// with the reason, when the draft does not pass ``checkAssemblyRecipe(_:)``, when its id is a
    /// built-in recipe's, or when `store` cannot be written.
    func saveAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft, to store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt
    /// Deletes the recipe `id` from `store`. Rows that already use it keep the copy they carry.
    func deleteAssemblyRecipe(_ id: UUID, from store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt
}
