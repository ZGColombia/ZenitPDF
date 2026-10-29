import Foundation
import ZPDFFormulaEngine
import ZPDFQuantityLedger

/// The office's own assembly recipes (NL-QTY-07 round 2): a file in Application Support, shared
/// by exporting and importing `.zpdfassembly` files — like tool sets and the rate library, with
/// no server. A recipe applied from here travels inside the project's assignment
/// (``LedgerAssemblyAssignment/definition``), so a colleague without the file sees the same rows.
public struct AssemblyRecipeLibrary: Sendable {

    public static let formatIdentifier = "zenit.assembly"
    public static let currentSchemaVersion = 1
    public static let fileExtension = "zpdfassembly"

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("recipes.\(Self.fileExtension)") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Zenit PDF/Assemblies`.
    public static func standard() -> AssemblyRecipeLibrary {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return AssemblyRecipeLibrary(directory: base
            .appendingPathComponent("Zenit PDF", isDirectory: true)
            .appendingPathComponent("Assemblies", isDirectory: true))
    }

    struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var recipes: [AssemblyDefinition]
    }

    /// Why a recipe file was not taken, in words.
    public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        case notARecipeFile
        case newerFormat(Int)
        case invalidRecipe(name: String, reason: String)
        case builtInIdentity(name: String)

        public var description: String {
            switch self {
            case .notARecipeFile:
                NSLocalizedString("This is not a Zenit PDF assembly recipe file.", comment: "Assembly import refusal")
            case .newerFormat(let version):
                String(format: NSLocalizedString("This recipe file was written by a newer Zenit PDF (format %d).", comment: "Assembly import refusal; the version"), version)
            case let .invalidRecipe(name, reason):
                String(format: NSLocalizedString("The recipe “%1$@” cannot be used: %2$@", comment: "Assembly import refusal; recipe name, reason"), name, reason)
            case .builtInIdentity(let name):
                String(format: NSLocalizedString("The recipe “%@” has the identity of a built-in recipe.", comment: "Assembly import refusal"), name)
            }
        }
    }

    /// The office's recipes, `[]` when none were saved; an unreadable file is an error.
    public func read() throws -> [AssemblyDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try Self.decode(Data(contentsOf: fileURL))
    }

    /// The recipes a `.zpdfassembly` file holds, each validated; refused whole on the first bad one.
    public static func decode(_ data: Data) throws -> [AssemblyDefinition] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == formatIdentifier else {
            throw Refusal.notARecipeFile
        }
        guard envelope.schemaVersion <= currentSchemaVersion else { throw Refusal.newerFormat(envelope.schemaVersion) }
        for recipe in envelope.recipes { try check(recipe) }
        return envelope.recipes
    }

    // MARK: - The one check (NL-QTY-07-UI)

    /// The check every recipe passes before it is kept — by an import, by the recipe editor and
    /// by a project read alike: not a built-in's identity, a valid definition, and every line a
    /// formula the engine compiles over the recipe's own inputs to the unit it declares.
    public static func check(_ recipe: AssemblyDefinition) throws {
        if let refusal = shapeRefusal(of: recipe) { throw refusal }
        if let (index, reason) = lineProblems(of: recipe).min(by: { $0.key < $1.key }) {
            throw Refusal.invalidRecipe(name: recipe.name, reason: "\(recipe.lines[index].name): \(reason)")
        }
    }

    /// The recipe-level half of ``check(_:)``: identity and definition, not the formulas.
    public static func shapeRefusal(of recipe: AssemblyDefinition) -> Refusal? {
        if LedgerAssemblyLibrary.definition(id: recipe.id) != nil { return .builtInIdentity(name: recipe.name) }
        do { try recipe.validate() } catch {
            return .invalidRecipe(name: recipe.name, reason: String(describing: error))
        }
        return nil
    }

    /// The line half of ``check(_:)``: why each line's formula cannot be used, by line index,
    /// in the formula engine's words. Empty when every line compiles.
    public static func lineProblems(of recipe: AssemblyDefinition) -> [Int: String] {
        let evaluator = AssemblyEvaluator(recipe)
        var problems: [Int: String] = [:]
        for index in recipe.lines.indices {
            if let reason = evaluator.staticRefusal(forLine: index) { problems[index] = reason.description }
        }
        return problems
    }

    // MARK: - Saving from the editor (NL-QTY-07-UI)

    /// Saves one recipe into the library, replacing the copy with the same id. Checked first.
    public func save(_ recipe: AssemblyDefinition) throws {
        try Self.check(recipe)
        var recipes = try read()
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        try write(recipes)
    }

    /// Removes the recipe `id`; `false` when the library had none.
    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        var recipes = try read()
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return false }
        recipes.remove(at: index)
        try write(recipes)
        return true
    }

    /// A `.zpdfassembly` file's bytes for `recipes`.
    public static func encode(_ recipes: [AssemblyDefinition]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(Envelope(format: formatIdentifier, schemaVersion: currentSchemaVersion, recipes: recipes))
    }

    /// Adds the recipes of a file to the library; a recipe with the same id replaces its old copy.
    /// - Returns: the names imported.
    @discardableResult
    public func importFile(at url: URL) throws -> [String] {
        let incoming = try Self.decode(Data(contentsOf: url))
        var recipes = try read()
        for recipe in incoming {
            if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
                recipes[index] = recipe
            } else {
                recipes.append(recipe)
            }
        }
        try write(recipes)
        return incoming.map(\.name)
    }

    /// Writes the whole library to a `.zpdfassembly` file to share.
    public func exportFile(to url: URL) throws {
        try Self.encode(try read()).write(to: url, options: .atomic)
    }

    func write(_ recipes: [AssemblyDefinition]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(recipes).write(to: fileURL, options: .atomic)
    }
}
