import Foundation
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The recipe editor's way into the document (NL-QTY-07-UI), installed on the ledger presenter
/// by ``AppCoreEnvironment``, which is the only object that holds the session, the command bus
/// and the office library together.
public struct AssemblyRecipeSeam {
    public var save: @MainActor (AssemblyDefinition, LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt
    public var delete: @MainActor (UUID, LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt

    public init(
        save: @escaping @MainActor (AssemblyDefinition, LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt,
        delete: @escaping @MainActor (UUID, LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt
    ) {
        self.save = save
        self.delete = delete
    }
}

// MARK: - Drafts and recipes

/// The one crossing between the editor's plain-value draft and the recipe the ledger runs.
public enum AssemblyRecipeDrafting {

    /// The recipe a draft describes. Names, notes and formulas are trimmed; an empty note is
    /// no note; a unit cost keeps its own currency.
    public static func definition(of draft: LedgerAssemblyRecipeDraft) -> AssemblyDefinition {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func note(_ text: String) -> String? { trimmed(text).isEmpty ? nil : trimmed(text) }
        return AssemblyDefinition(
            id: draft.id,
            name: trimmed(draft.name),
            note: note(draft.note),
            inputs: draft.inputs.map {
                AssemblyInput(name: trimmed($0.name), dimension: Domain.Dimension(shown: $0.dimension), note: note($0.note))
            },
            lines: draft.lines.map {
                AssemblyLine(
                    name: trimmed($0.name),
                    source: trimmed($0.formula),
                    outputDimension: Domain.Dimension(shown: $0.dimension),
                    note: note($0.note),
                    unitCost: $0.unitCost.map { Domain.Quantity(shown: $0) }
                )
            }
        )
    }

    /// The draft that edits a recipe.
    public static func draft(of recipe: AssemblyDefinition) -> LedgerAssemblyRecipeDraft {
        LedgerAssemblyRecipeDraft(
            id: recipe.id,
            name: recipe.name,
            note: recipe.note ?? "",
            inputs: recipe.inputs.map {
                .init(name: $0.name, dimension: Shown.Dimension(domain: $0.dimension), note: $0.note ?? "")
            },
            lines: recipe.lines.map {
                .init(
                    name: $0.name,
                    formula: $0.formulaText,
                    dimension: Shown.Dimension(domain: $0.outputDimension),
                    unitCost: $0.unitCost.map { Shown.Quantity(domain: $0) },
                    note: $0.note ?? ""
                )
            }
        )
    }

    /// A draft checked exactly as a recipe file is checked on import: the recipe-level refusal
    /// in the importer's words, and each line's formula problem in the formula engine's.
    public static func check(_ draft: LedgerAssemblyRecipeDraft) -> LedgerAssemblyRecipeCheck {
        let recipe = definition(of: draft)
        return LedgerAssemblyRecipeCheck(
            refusal: AssemblyRecipeLibrary.shapeRefusal(of: recipe)?.description,
            lineProblems: AssemblyRecipeLibrary.lineProblems(of: recipe),
            measuredInputs: Set(recipe.inputs.indices.filter { recipe.inputs[$0].measurementField != nil })
        )
    }
}

// MARK: - The presenter's side

extension AppLedgerPresenter: LedgerAssemblyRecipeEditing {

    public var assemblyRecipes: [LedgerAssemblyRecipeEntry] {
        let project = Set(projectAssemblies.map(\.id))
        return AssemblyOffer.definitions(office: officeAssemblies, project: projectAssemblies).map { recipe in
            let store: LedgerAssemblyRecipeStore = LedgerAssemblyLibrary.definition(id: recipe.id) != nil
                ? .builtIn
                : (project.contains(recipe.id) ? .project : .office)
            return LedgerAssemblyRecipeEntry(draft: AssemblyRecipeDrafting.draft(of: recipe), store: store)
        }
    }

    /// The office library first when there is one — a recipe is usually an office standard —
    /// then this project.
    public var assemblyRecipeStores: [LedgerAssemblyRecipeStore] {
        guard assemblyRecipeSeam != nil else { return [] }
        return officeRecipeLibrary == nil ? [.project] : [.office, .project]
    }

    public var assemblyRecipeCurrencyCode: String { defaultCurrencyCode }

    public func checkAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft) -> LedgerAssemblyRecipeCheck {
        AssemblyRecipeDrafting.check(draft)
    }

    public func saveAssemblyRecipe(_ draft: LedgerAssemblyRecipeDraft, to store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        guard let assemblyRecipeSeam else { return .failure(AppCoreEnvironment.noRecipeDocument) }
        return await assemblyRecipeSeam.save(AssemblyRecipeDrafting.definition(of: draft), store)
    }

    public func deleteAssemblyRecipe(_ id: UUID, from store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        guard let assemblyRecipeSeam else { return .failure(AppCoreEnvironment.noRecipeDocument) }
        return await assemblyRecipeSeam.delete(id, store)
    }
}

// MARK: - Saving and deleting

extension AppCoreEnvironment {

    static let noRecipeDocument = NSLocalizedString(
        "Recipes cannot be saved here: no document is attached to this ledger.",
        comment: "Assembly recipe editor refusal when the ledger has no document"
    )

    /// Installs the ledger's recipe seam. Called once, by ``make(session:documentID:undoManager:)``.
    func installAssemblyRecipeSeam() {
        ledger.assemblyRecipeSeam = AssemblyRecipeSeam(
            save: { [weak self] recipe, store in
                await self?.saveAssemblyRecipe(recipe, to: store) ?? .failure(Self.noRecipeDocument)
            },
            delete: { [weak self] id, store in
                await self?.deleteAssemblyRecipe(id, from: store) ?? .failure(Self.noRecipeDocument)
            }
        )
    }

    /// Saves `recipe` to the office library or to this project, replacing the copy with the same
    /// id there — after the one check an import makes — and then brings this project's measured
    /// rows that carry an older copy of it up to date, as one undoable step, so their derived
    /// rows (and their unit costs) follow at once.
    public func saveAssemblyRecipe(_ recipe: AssemblyDefinition, to store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        do { try AssemblyRecipeLibrary.check(recipe) } catch {
            return .failure(String(describing: error))
        }
        switch store {
        case .builtIn:
            return .failure(NSLocalizedString(
                "Built-in recipes cannot be changed. Duplicate the recipe and edit the copy.",
                comment: "Assembly recipe editor refusal: saving over a built-in recipe"
            ))
        case .office:
            guard let library = officeRecipeLibrary else {
                return .failure(NSLocalizedString(
                    "There is no office library to save into here.",
                    comment: "Assembly recipe editor refusal: no office recipe library"
                ))
            }
            do {
                try library.save(recipe)
                let office = try library.read()
                for environment in documentEnvironments { environment.ledger.officeAssemblies = office }
            } catch {
                return .failure(String(describing: error))
            }
        case .project:
            let current = await session.projectAssemblyRecipes
            guard current.isReadable else { return .failure(Self.unreadableProjectRecipes) }
            var recipes = current.recipes
            if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
                recipes[index] = recipe
            } else {
                recipes.append(recipe)
            }
            if let refusal = Self.projectRecipesTooLarge(recipes) { return .failure(refusal) }
            await setProjectRecipes(recipes)
        }
        return await updateRows(carrying: recipe)
    }

    /// Deletes the recipe `id` from the office library or from this project. Rows that already
    /// use it keep deriving from the copy they carry (ADR-0024 round 2).
    public func deleteAssemblyRecipe(_ id: UUID, from store: LedgerAssemblyRecipeStore) async -> LedgerAssemblyRecipeReceipt {
        let missing = NSLocalizedString(
            "That recipe is not there any more; nothing was deleted.",
            comment: "Assembly recipe editor refusal: deleting a recipe that is gone"
        )
        switch store {
        case .builtIn:
            return .failure(NSLocalizedString(
                "Built-in recipes cannot be deleted.",
                comment: "Assembly recipe editor refusal: deleting a built-in recipe"
            ))
        case .office:
            guard let library = officeRecipeLibrary else { return .failure(missing) }
            do {
                guard try library.remove(id: id) else { return .failure(missing) }
                let office = try library.read()
                for environment in documentEnvironments { environment.ledger.officeAssemblies = office }
            } catch {
                return .failure(String(describing: error))
            }
        case .project:
            let current = await session.projectAssemblyRecipes
            guard current.isReadable else { return .failure(Self.unreadableProjectRecipes) }
            guard current.recipes.contains(where: { $0.id == id }) else { return .failure(missing) }
            await setProjectRecipes(current.recipes.filter { $0.id != id })
        }
        return LedgerAssemblyRecipeReceipt()
    }

    /// Every environment of this document — its own core and each second window's view
    /// (NL-UX-20) — so a recipe saved in one window is offered in all of them.
    private var documentEnvironments: [AppCoreEnvironment] {
        let root = primaryEnvironment ?? self
        return [root] + root.windowViews
    }

    /// The office library this document saves into: this window's, else the document's own.
    private var officeRecipeLibrary: AssemblyRecipeLibrary? {
        ledger.officeRecipeLibrary ?? (primaryEnvironment ?? self).ledger.officeRecipeLibrary
    }

    /// Stores the project's list, offers it in every window, and tells the document.
    private func setProjectRecipes(_ recipes: [AssemblyDefinition]) async {
        await session.setProjectAssemblyRecipes(recipes)
        for environment in documentEnvironments { environment.ledger.projectAssemblies = recipes }
        (ledger.onProjectAssembliesChanged ?? (primaryEnvironment ?? self).ledger.onProjectAssembliesChanged)?()
    }

    /// Rewrites every unlocked row whose assignment carries an older copy of `recipe` with the
    /// same parameters and the new copy — one batch, one ⌘Z. Locked rows keep their copy and
    /// are counted.
    func updateRows(carrying recipe: AssemblyDefinition) async -> LedgerAssemblyRecipeReceipt {
        var batch: [DocumentCommand] = []
        var locked = 0
        for record in await session.markupsCarryingRecipe(recipe.id) {
            guard var assignment = LedgerAssemblyAssignment(cell: record.customValues[AssemblyColumn.columnID]),
                  assignment.definition != recipe else { continue }
            if record.locked { locked += 1; continue }
            assignment.definition = recipe
            batch.append(.editCustomValue(id: record.id, column: AssemblyColumn.columnID, value: assignment.cellValue))
        }
        guard !batch.isEmpty else { return LedgerAssemblyRecipeReceipt(lockedRowCount: locked) }
        do {
            let outcome = try await commands.performBatch(batch, actionName: NSLocalizedString(
                "Update Assembly Recipe",
                comment: "Undo action name: rows brought up to date with an edited assembly recipe"
            ))
            await ledger.refresh()
            return LedgerAssemblyRecipeReceipt(updatedRowCount: outcome?.changedMarkupIDs.count ?? 0, lockedRowCount: locked)
        } catch {
            return LedgerAssemblyRecipeReceipt(
                failureDescription: String(format: NSLocalizedString(
                    "The recipe was saved, but the rows that use it were not updated: %@",
                    comment: "Assembly recipe editor: saved, rows refused; the placeholder is the reason"
                ), String(describing: error)),
                lockedRowCount: locked
            )
        }
    }

    static let unreadableProjectRecipes = NSLocalizedString(
        "This project's recipes were saved by a newer Zenit PDF and are kept as they are. Save the recipe to the office library instead.",
        comment: "Assembly recipe editor refusal: the project's stored recipes cannot be read by this version"
    )

    /// The refusal for a project list the file cannot hold, or `nil`.
    static func projectRecipesTooLarge(_ recipes: [AssemblyDefinition]) -> String? {
        let bytes = ((try? ProjectAssemblyRecipeArchive.json(for: recipes)) ?? nil)?.utf8.count ?? 0
        guard bytes > ProjectAssemblyRecipeArchive.maximumByteCount else { return nil }
        return String(format: NSLocalizedString(
            "This project cannot hold more recipes: together they would take %1$d KB, and a project keeps at most %2$d KB. Save this one to the office library instead.",
            comment: "Assembly recipe editor refusal: project recipe list too large; sizes in KB"
        ), (bytes + 1023) / 1024, ProjectAssemblyRecipeArchive.maximumByteCount / 1024)
    }
}
