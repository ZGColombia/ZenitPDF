import Foundation
import ZPDFContracts
import ZPDFPersistence

/// Where a table import's ledger columns lived in a project package before the takeoff
/// database could hold them. Now read once, for packages written by that build, and retired
/// on the next save; the durable home is `TakeoffArchive` (custom_column.definition_json).
///
/// `TakeoffSession.addCustomColumns` keeps runtime columns in memory only, while the imported
/// rows' cells *are* archived, keyed by the columns' ids. So a saved and reopened project came
/// back with every imported cell orphaned — no column definition existed for them, and the
/// status note had said "12 read rows added" (BH-075). This file is the definitions' home in
/// the package, written with the takeoff and read back before hydration, so the cells find
/// their columns (and number cells are re-tagged by the right column) on every open.
///
/// A plain JSON member under `attachments/`, beside the photo sidecar, because the working
/// package is edited in place and that directory already survives every save, version clone
/// and Save As copy.
enum ImportedLedgerColumnStore {

    static let fileName = "imported-ledger-columns.json"

    static func url(inPackage packageURL: URL) -> URL {
        packageURL.member(ProjectPackageLayout.attachments).appendingPathComponent(fileName)
    }

    /// Writes the definitions, or removes the file when there are none.
    static func write(_ definitions: [LedgerColumnDefinition], toPackage packageURL: URL) throws {
        let target = url(inPackage: packageURL)
        guard !definitions.isEmpty else {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(definitions).write(to: target, options: .atomic)
    }

    /// Removes the interim file once the takeoff archive carries the definitions itself
    /// (custom_column.definition_json). Best effort: a file that cannot be removed is only
    /// read again, and the session ignores a definition it already holds.
    static func retire(inPackage packageURL: URL) {
        let target = url(inPackage: packageURL)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// The stored definitions; empty when there are none or the file is unreadable. Bounded,
    /// so a hostile package cannot make the open allocate without limit.
    static func read(fromPackage packageURL: URL?) -> [LedgerColumnDefinition] {
        guard let packageURL else { return [] }
        let target = url(inPackage: packageURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: target),
              let definitions = try? JSONDecoder().decode([LedgerColumnDefinition].self, from: data)
        else { return [] }
        return Array(definitions.prefix(512))
    }
}
