import Foundation
import ZPDFExport

/// The person's installed export profiles (NL-PLAT-08, NL-PLAT-23): one `.zpdfprofile` per
/// profile in `Application Support/Zenit PDF/Export Profiles/`, so File ▸ Export with Profile… can
/// offer the office's profiles by name instead of asking for a file every time, and a pack can
/// install them.
///
/// Files, not a database: a profile is a small JSON document a person may adjust by hand, and the
/// folder is theirs to inspect. Every read goes through ``LedgerExportProfile/read(_:)``, the same
/// validator an opened file goes through.
struct ExportProfileLibrary: Sendable {

    let directory: URL

    /// Where the shipping application keeps them. Injectable, and guarded by construction as
    /// well (S-021): outside the assembled application the default is a per-process temporary
    /// directory, so a test that forgets to inject never reads or rewrites the real Application
    /// Support — saving and applying a job template both reach this library.
    @MainActor static var standardDirectory: () -> URL = {
        guard ZenitProcessDefaults.isAssembledApplication else { return scratchDirectory }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Zenit PDF", isDirectory: true)
            .appendingPathComponent("Export Profiles", isDirectory: true)
    }

    /// The library outside the assembled application: one temporary directory per process.
    static let scratchDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zenitpdf-export-profiles-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    @MainActor static func standard() -> ExportProfileLibrary { ExportProfileLibrary(directory: standardDirectory()) }

    /// Every readable profile, by name. A file that does not validate is skipped and named.
    func profiles() -> (profiles: [LedgerExportProfile], unreadable: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var profiles: [LedgerExportProfile] = []
        var unreadable: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == LedgerExportProfile.fileExtension {
            if let data = try? Data(contentsOf: file), let profile = try? LedgerExportProfile.read(data) {
                profiles.append(profile)
            } else {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, unreadable)
    }

    /// Installs a profile under its own name. One of the same name is replaced: a profile is
    /// identified by its name in the picker, and an office's newer copy is the point of a pack.
    ///
    /// - Returns: whether a profile of that name was replaced.
    @discardableResult
    func install(_ profile: LedgerExportProfile) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: profile.name))
        let replaced = FileManager.default.fileExists(atPath: url.path)
        try profile.encoded().write(to: url, options: .atomic)
        return replaced
    }

    /// A file name for a profile: its name with the characters a file system could misread
    /// replaced.
    static func fileName(for name: String) -> String {
        var safe = name.map { "/\\:\0".contains($0) ? "-" : String($0) }.joined()
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty || safe.hasPrefix(".") { safe = "Profile" + safe }
        return safe + "." + LedgerExportProfile.fileExtension
    }
}
