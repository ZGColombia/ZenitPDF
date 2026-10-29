import Foundation
import GRDB
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFPersistence
import ZPDFQuantityLedger

/// The assembly recipes saved inside one project (NL-QTY-07-UI).
///
/// An office recipe lives in Application Support and is shared by file; a project recipe lives
/// in the project, in schema v18's `project_setting` under ``ProjectAssemblyRecipeArchive/key``,
/// as the same `.zpdfassembly` envelope a recipe file holds — checked by the same
/// ``AssemblyRecipeLibrary/check(_:)`` on the way in. Persistence stores the text and does not
/// interpret it, so this needs no migration.
public struct ProjectAssemblyRecipes: Hashable, Sendable {
    /// The recipes, in the order they were first saved.
    public var recipes: [AssemblyDefinition]
    /// `false` when the stored list could not be read — written by a newer Zenit PDF, or
    /// damaged. It is then kept in the file untouched by every save, and nothing is saved into
    /// it here, so a colleague's newer recipes are never replaced by an empty list.
    public var isReadable: Bool

    public init(recipes: [AssemblyDefinition], isReadable: Bool = true) {
        self.recipes = recipes
        self.isReadable = isReadable
    }

    /// No recipes, and free to save into.
    public static let none = ProjectAssemblyRecipes(recipes: [])
}

/// Reads and writes a project's recipes inside the takeoff archive's transaction.
enum ProjectAssemblyRecipeArchive {

    /// The `project_setting` key.
    static let key = "assembly_recipes"

    /// The largest list kept, in UTF-8 bytes — the settings table's own bound.
    static var maximumByteCount: Int { MarkupLayerStore.maximumSettingByteCount }

    /// What a save does with the key.
    enum Row: Sendable {
        /// Leave the stored text alone: the state does not carry the list, or it was unreadable.
        case leave
        /// Store this text, or remove the key with `nil` (no recipes).
        case store(String?)
    }

    /// The text for a list, or `nil` for an empty one.
    static func json(for recipes: [AssemblyDefinition]) throws -> String? {
        guard !recipes.isEmpty else { return nil }
        return String(decoding: try AssemblyRecipeLibrary.encode(recipes), as: UTF8.self)
    }

    /// The row for `state`, built before the transaction so a bad value fails the save before
    /// anything is touched.
    static func row(of state: TakeoffSession.TakeoffState) throws -> Row {
        guard let carried = state.projectAssemblyRecipes, carried.isReadable else { return .leave }
        return .store(try json(for: carried.recipes))
    }

    static func write(_ row: Row, project projectId: String, in db: Database) throws {
        guard case .store(let json) = row, try db.tableExists("project_setting") else { return }
        try MarkupLayerStore.setSetting(key, json: json, project: projectId, in: db)
    }

    /// The stored list; `.none` when there is none (or the package predates v18), and an
    /// unreadable, empty value when the text does not pass the recipe check.
    static func read(project projectId: String, in db: Database) throws -> ProjectAssemblyRecipes {
        guard let json = try MarkupLayerStore.setting(key, project: projectId, in: db) else { return .none }
        guard let recipes = try? AssemblyRecipeLibrary.decode(Data(json.utf8)) else {
            return ProjectAssemblyRecipes(recipes: [], isReadable: false)
        }
        return ProjectAssemblyRecipes(recipes: recipes)
    }
}

extension TakeoffSession.TakeoffState {

    /// This state carrying the project's own assembly recipes.
    func carryingAssemblyRecipes(_ recipes: ProjectAssemblyRecipes) -> Self {
        var state = self
        state.projectAssemblyRecipes = recipes
        return state
    }
}

extension TakeoffSession {

    /// Installs the recipes a project was saved with. Called by the document load before the
    /// environment is built; no undo, like the rest of hydration.
    public func restoreProjectAssemblyRecipes(_ recipes: ProjectAssemblyRecipes) {
        projectAssemblyRecipes = recipes
    }

    /// Replaces the project's recipes. The next save writes them.
    func setProjectAssemblyRecipes(_ recipes: [AssemblyDefinition]) {
        projectAssemblyRecipes = ProjectAssemblyRecipes(recipes: recipes)
    }

    /// The project's measured markups whose assignment carries a copy of the recipe `id` — the
    /// rows a saved edit of that recipe brings up to date.
    func markupsCarryingRecipe(_ id: UUID) -> [ZPDFContracts.MarkupRecord] {
        ledgerMarkups.filter { record in
            guard let assignment = LedgerAssemblyAssignment(cell: record.customValues[AssemblyColumn.columnID]) else { return false }
            return assignment.assemblyID == id && assignment.definition != nil
        }
    }
}
