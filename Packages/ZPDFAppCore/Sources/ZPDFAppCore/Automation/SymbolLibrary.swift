import Foundation
import ZPDFVectorExtraction

/// A local library of confirmed symbols that learns by example (NL-AUTO-17).
///
/// Every symbol a person boxed, named and accepted can be kept here, and the next sheet — or the
/// next project — can be searched for all of them at once. There is no training and no model
/// file: an entry is the exemplar itself (its feature points, extent and majority style), its
/// designation, and when it was saved. The library is one JSON file on this Mac that the person
/// can delete; nothing in it leaves the machine.
public struct SymbolLibraryEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var designation: String
    public let exemplar: SymbolExemplar
    public let savedAt: Date

    public init(id: UUID = UUID(), designation: String, exemplar: SymbolExemplar, savedAt: Date) {
        self.id = id
        self.designation = designation
        self.exemplar = exemplar
        self.savedAt = savedAt
    }
}

/// The library file. Reads and writes are whole-file and atomic; a file that cannot be read is
/// reported, never silently replaced by an empty one.
public struct SymbolLibrary: Sendable {

    public enum LibraryError: Error, Sendable, Equatable {
        /// The file exists and is not a library this build can read. It is left untouched.
        case unreadable(String)
    }

    /// Where the file lives.
    public let fileURL: URL

    /// The most entries a library holds; the oldest go first beyond it.
    public static let capacity = 500

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    struct File: Codable {
        var version: Int
        var entries: [SymbolLibraryEntry]
    }

    static let formatVersion = 1

    /// Every entry, newest first. An absent file is an empty library.
    public func entries() throws -> [SymbolLibraryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: Data(contentsOf: fileURL))
            guard file.version <= Self.formatVersion else {
                throw LibraryError.unreadable("library format \(file.version) is newer than this build reads")
            }
            return file.entries.sorted { $0.savedAt > $1.savedAt }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.unreadable(String(describing: error))
        }
    }

    /// Adds an entry. One per designation: saving "D-12" again replaces the earlier D-12.
    @discardableResult
    public func add(designation: String, exemplar: SymbolExemplar, at date: Date = Date()) throws -> SymbolLibraryEntry {
        let name = designation.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = try entries().filter { $0.designation.caseInsensitiveCompare(name) != .orderedSame }
        let entry = SymbolLibraryEntry(designation: name, exemplar: exemplar, savedAt: date)
        current.insert(entry, at: 0)
        try write(Array(current.prefix(Self.capacity)))
        return entry
    }

    /// Removes one entry.
    public func remove(id: UUID) throws {
        try write(try entries().filter { $0.id != id })
    }

    private func write(_ entries: [SymbolLibraryEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(version: Self.formatVersion, entries: entries)).write(to: fileURL, options: .atomic)
    }
}
