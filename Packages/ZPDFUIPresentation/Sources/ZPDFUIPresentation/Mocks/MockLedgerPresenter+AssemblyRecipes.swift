// Debug and test builds only (R-142), like the mock it extends.
#if DEBUG || ZPDF_MOCKS
import Foundation

// MARK: - LedgerAssemblyRecipeEditing (NL-QTY-07-UI)

extension MockLedgerPresenter: LedgerAssemblyRecipeEditing {

    /// The mock's one built-in recipe, as a draft: the timber stud wall of ``availableAssemblies``.
    public static let mockBuiltInRecipe = LedgerAssemblyRecipeDraft(
        id: UUID(uuidString: "5A504446-4153-4D42-0000-000000000001")!,
        name: "Timber stud wall",
        inputs: [
            .init(name: "Length", dimension: .length),
            .init(name: "Height", dimension: .length),
            .init(name: "Spacing", dimension: .length)
        ],
        lines: [.init(name: "Studs", formula: "FLOOR(Length / Spacing) + 1", dimension: .count)]
    )

    public var assemblyRecipes: [LedgerAssemblyRecipeEntry] {
        [LedgerAssemblyRecipeEntry(draft: Self.mockBuiltInRecipe, store: .builtIn)] + mockAssemblyRecipes
    }

    public var assemblyRecipeStores: [LedgerAssemblyRecipeStore] { [.project, .office] }

    public var assemblyRecipeCurrencyCode: String { "SEK" }

    /// The shape checks only — the mock has no formula engine: a name, a line, and a formula
    /// and name on every line.
    public func checkAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft) -> LedgerAssemblyRecipeCheck {
        let measured = Set(draft.inputs.indices.filter {
            ["length", "height", "area", "perimeter"].contains(draft.inputs[$0].name.trimmingCharacters(in: .whitespaces).lowercased())
        })
        var problems: [Int: String] = [:]
        for (index, line) in draft.lines.enumerated()
        where line.formula.trimmingCharacters(in: .whitespaces).isEmpty {
            problems[index] = "The formula is empty."
        }
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return LedgerAssemblyRecipeCheck(refusal: "An assembly needs a name.", lineProblems: problems, measuredInputs: measured)
        }
        if draft.lines.isEmpty {
            return LedgerAssemblyRecipeCheck(refusal: "The assembly produces nothing: it has no lines.", lineProblems: problems, measuredInputs: measured)
        }
        if draft.id == Self.mockBuiltInRecipe.id {
            return LedgerAssemblyRecipeCheck(refusal: "The recipe has the identity of a built-in recipe.", lineProblems: problems, measuredInputs: measured)
        }
        return LedgerAssemblyRecipeCheck(lineProblems: problems, measuredInputs: measured)
    }

    public func saveAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft, to store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        let check = checkAssemblyRecipe(draft)
        if let refusal = check.refusal { return .failure(refusal) }
        if let problem = check.lineProblems.sorted(by: { $0.key < $1.key }).first { return .failure(problem.value) }
        guard store != .builtIn else { return .failure("Built-in recipes cannot be changed.") }
        let entry = LedgerAssemblyRecipeEntry(draft: draft, store: store)
        if let index = mockAssemblyRecipes.firstIndex(where: { $0.id == draft.id }) {
            mockAssemblyRecipes[index] = entry
        } else {
            mockAssemblyRecipes.append(entry)
        }
        return LedgerAssemblyRecipeReceipt()
    }

    public func deleteAssemblyRecipe(_ id: UUID, from store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        guard let index = mockAssemblyRecipes.firstIndex(where: { $0.id == id && $0.store == store }) else {
            return .failure("There is no such recipe to delete.")
        }
        mockAssemblyRecipes.remove(at: index)
        return LedgerAssemblyRecipeReceipt()
    }
}
#endif
