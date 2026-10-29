import Foundation
import ZPDFSpreadsheet

/// One `.zpdfpack`: a zip holding `pack.json` and Zenit data files (NL-PLAT-23, phase 1).
///
/// The posture is the import validators': the file is untrusted, every limit is checked before
/// anything is believed, and the pack is refused *whole* — with the reason — when any member is
/// not a data file this build knows. A pack that carries a script, an executable, a nested
/// archive or a file it does not list is not a pack; installing half of it would teach people to
/// trust the other half. Nothing in a pack runs.
public struct ZenitPack: Sendable, Equatable {

    public static let fileExtension = "zpdfpack"
    public static let manifestName = "pack.json"
    public static let formatName = "zenit-pack"
    public static let currentFormatVersion = 1

    /// What a member is, by its extension.
    public enum ItemKind: String, Sendable, Codable, CaseIterable {
        case toolSet
        case jobTemplate
        case exportProfile

        public var fileExtension: String {
            switch self {
            case .toolSet: return "zpdftools"
            case .jobTemplate: return "zpdftemplate"
            case .exportProfile: return "zpdfprofile"
            }
        }

        public static func of(path: String) -> ItemKind? {
            let ext = (path as NSString).pathExtension.lowercased()
            return allCases.first { $0.fileExtension == ext }
        }
    }

    /// The manifest, as written.
    public struct Manifest: Sendable, Equatable, Codable {
        public var format: String
        public var formatVersion: Int
        public var name: String
        public var version: String
        public var author: String?
        public var summary: String?
        public var items: [Item]

        public struct Item: Sendable, Equatable, Codable {
            public var path: String
            public var kind: ItemKind
            public init(path: String, kind: ItemKind) {
                self.path = path
                self.kind = kind
            }
        }

        public init(name: String, version: String, author: String? = nil, summary: String? = nil, items: [Item]) {
            self.format = ZenitPack.formatName
            self.formatVersion = ZenitPack.currentFormatVersion
            self.name = name
            self.version = version
            self.author = author
            self.summary = summary
            self.items = items
        }
    }

    /// One member's bytes, not yet validated by its own importer.
    public struct Item: Sendable, Equatable {
        public let path: String
        public let kind: ItemKind
        public let data: Data

        public var fileName: String { (path as NSString).lastPathComponent }
    }

    public let manifest: Manifest
    public let items: [Item]

    public func items(of kind: ItemKind) -> [Item] { items.filter { $0.kind == kind } }

    /// Limits for an untrusted pack. Data files are small; a pack of a whole office library is
    /// a few megabytes.
    public struct Limits: Sendable, Equatable {
        public var maximumFileBytes: Int
        public var maximumItems: Int
        public var zip: ZipLimits

        public init(maximumFileBytes: Int = 64 * 1024 * 1024, maximumItems: Int = 256,
                    zip: ZipLimits = ZipLimits(maximumEntryCount: 257, maximumEntryBytes: 16 * 1024 * 1024,
                                               maximumTotalBytes: 128 * 1024 * 1024, maximumCompressionRatio: 200)) {
            self.maximumFileBytes = maximumFileBytes
            self.maximumItems = maximumItems
            self.zip = zip
        }

        public static let standard = Limits()
    }

    /// Why a pack was refused. Each case names what was found.
    public enum ReadError: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge(bytes: Int, limit: Int)
        case container(ZipError)
        case noManifest
        case unreadableManifest(String)
        case notAPack(format: String)
        case newerFormat(Int)
        case tooManyItems(count: Int, limit: Int)
        case emptyPack
        case unsafePath(String)
        case notADataFile(String)
        case kindMismatch(path: String, declared: ItemKind)
        case unlisted(String)
        case missing(String)
        case duplicate(String)

        public var description: String {
            switch self {
            case let .tooLarge(bytes, limit):
                return "The pack is \(bytes) bytes; the limit is \(limit)."
            case let .container(error):
                return "The pack could not be opened: \(error.description)."
            case .noManifest:
                return "The pack has no \(ZenitPack.manifestName), so there is no list of what it holds."
            case let .unreadableManifest(reason):
                return "The pack's list of contents could not be read: \(reason)."
            case let .notAPack(format):
                return "The file says it is “\(format)”, not a Zenit pack."
            case let .newerFormat(version):
                return "The pack was made by a newer Zenit PDF (format \(version)). Update Zenit PDF to install it."
            case let .tooManyItems(count, limit):
                return "The pack lists \(count) files; the limit is \(limit)."
            case .emptyPack:
                return "The pack lists no files."
            case let .unsafePath(path):
                return "“\(path)” is not a safe name inside a pack."
            case let .notADataFile(path):
                return "“\(path)” is not a tool set, a job template or an export profile. A pack holds only those, and nothing in it runs."
            case let .kindMismatch(path, declared):
                return "“\(path)” is listed as a \(declared.rawValue) but its name says otherwise."
            case let .unlisted(path):
                return "“\(path)” is in the pack but not in its list of contents."
            case let .missing(path):
                return "The pack lists “\(path)” but does not contain it."
            case let .duplicate(path):
                return "The pack lists “\(path)” twice."
            }
        }
    }

    /// Reads and checks a pack. Nothing is installed; the caller hands each item to its importer.
    public static func read(_ data: Data, limits: Limits = .standard) throws -> ZenitPack {
        guard data.count <= limits.maximumFileBytes else { throw ReadError.tooLarge(bytes: data.count, limit: limits.maximumFileBytes) }
        let archive: ZipArchiveReader
        do {
            archive = try ZipArchiveReader(data: data, limits: limits.zip)
        } catch let error as ZipError {
            throw ReadError.container(error)
        }
        // Every member first, before the manifest is believed: a script is refused even when the
        // manifest does not mention it.
        for entry in archive.entries {
            if entry.name.hasSuffix("/") { continue } // a directory record carries no bytes
            guard ZipStoredWriter.isSafeEntryName(entry.name) else { throw ReadError.unsafePath(entry.name) }
            guard entry.name == manifestName || ItemKind.of(path: entry.name) != nil else {
                throw ReadError.notADataFile(entry.name)
            }
        }
        guard archive.entry(named: manifestName) != nil else { throw ReadError.noManifest }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: archive.contents(of: manifestName))
        } catch let error as ZipError {
            throw ReadError.container(error)
        } catch {
            throw ReadError.unreadableManifest(String(describing: error))
        }
        guard manifest.format == formatName else { throw ReadError.notAPack(format: manifest.format) }
        guard manifest.formatVersion <= currentFormatVersion else { throw ReadError.newerFormat(manifest.formatVersion) }
        guard !manifest.items.isEmpty else { throw ReadError.emptyPack }
        guard manifest.items.count <= limits.maximumItems else {
            throw ReadError.tooManyItems(count: manifest.items.count, limit: limits.maximumItems)
        }
        var seen: Set<String> = []
        var items: [Item] = []
        for listed in manifest.items {
            guard ZipStoredWriter.isSafeEntryName(listed.path) else { throw ReadError.unsafePath(listed.path) }
            guard seen.insert(listed.path).inserted else { throw ReadError.duplicate(listed.path) }
            guard let kind = ItemKind.of(path: listed.path) else { throw ReadError.notADataFile(listed.path) }
            guard kind == listed.kind else { throw ReadError.kindMismatch(path: listed.path, declared: listed.kind) }
            guard archive.entry(named: listed.path) != nil else { throw ReadError.missing(listed.path) }
            do {
                items.append(Item(path: listed.path, kind: kind, data: try archive.contents(of: listed.path)))
            } catch let error as ZipError {
                throw ReadError.container(error)
            }
        }
        for entry in archive.entries where !entry.name.hasSuffix("/") && entry.name != manifestName {
            guard seen.contains(entry.name) else { throw ReadError.unlisted(entry.name) }
        }
        return ZenitPack(manifest: manifest, items: items)
    }

    /// Writes a pack: the manifest first, then each item under the path the manifest gives it.
    public static func write(manifest: Manifest, files: [String: Data]) throws -> Data {
        var writer = ZipStoredWriter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer.add(manifestName, data: encoder.encode(manifest))
        for item in manifest.items {
            guard let data = files[item.path] else { throw ReadError.missing(item.path) }
            guard ItemKind.of(path: item.path) == item.kind else { throw ReadError.kindMismatch(path: item.path, declared: item.kind) }
            try writer.add(item.path, data: data)
        }
        return try writer.archive()
    }

    /// A path inside a pack for a file of `kind` called `name`: the kind's folder, a name with the
    /// characters a zip or a file system could misread replaced, and the kind's extension.
    public static func suggestedPath(kind: ItemKind, name: String) -> String {
        let folder: String
        switch kind {
        case .toolSet: folder = "tools"
        case .jobTemplate: folder = "templates"
        case .exportProfile: folder = "profiles"
        }
        var safe = name.map { "/\\:\0".contains($0) ? "-" : $0 }.map(String.init).joined()
        safe = safe.trimmingCharacters(in: .whitespaces)
        if safe.isEmpty || safe == "." || safe == ".." { safe = "Untitled" }
        return "\(folder)/\(safe).\(kind.fileExtension)"
    }
}
