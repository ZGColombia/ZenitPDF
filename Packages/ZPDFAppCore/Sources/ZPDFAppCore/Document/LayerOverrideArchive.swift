import Foundation
import GRDB
import ZPDFPersistence

/// Where a project keeps its PDF layer visibility (R-205): the `layer_override` rows of schema
/// v3, which nothing wrote before — a layer hidden in the Navigator came back on at the next
/// open.
///
/// Scoped to the package's primary drawing, the one whose `/OCProperties` the Navigator lists.
/// Writes go through the package's session database handle as they happen, in order, like the
/// History feed's: a layer toggle is a view setting, not an edit, so it neither waits for ⌘S
/// nor marks the document changed, and a clean close keeps it. Only the `visible` column is
/// this archive's; a stored `locked` override is left as it was.
@MainActor
public final class LayerOverrideArchive {

    private let package: ProjectPackage
    private var pending: Task<Void, Never>?

    public init(package: ProjectPackage) {
        self.package = package
    }

    /// The stored visibility overrides, `PDFLayerID.rawValue` → visible. Empty when nothing is
    /// stored or the rows cannot be read: a layer state that cannot be restored degrades to the
    /// document default, never to an error on open.
    public func load() async -> [String: Bool] {
        guard let scope = try? await scope() else { return [:] }
        return (try? await package.read { db in
            try LayerOverrideStore.visibilityOverrides(db, projectId: scope.project, documentId: scope.document)
        }) ?? [:]
    }

    /// Replaces the stored visibility overrides with `overrides`. Queued behind the previous
    /// save, so two quick toggles land in the order they were made.
    public func save(_ overrides: [String: Bool]) {
        let previous = pending
        let package = package
        pending = Task { @MainActor [weak self] in
            await previous?.value
            guard let scope = try? await self?.scope() else { return }
            let database = await package.database
            _ = try? await database.write { db in
                try Self.replaceVisibility(overrides, project: scope.project, document: scope.document, in: db)
            }
        }
    }

    /// Waits for every queued save.
    public func settle() async {
        while let task = pending {
            await task.value
            if pending == task { pending = nil }
        }
    }

    private var cachedScope: (project: String, document: String)?

    private func scope() async throws -> (project: String, document: String) {
        if let cachedScope { return cachedScope }
        let project = await package.manifest.projectId
        let document = try await TakeoffArchive.primaryDocumentIdentifier(of: package)
        cachedScope = (project, document)
        return (project, document)
    }

    private nonisolated static func replaceVisibility(
        _ overrides: [String: Bool], project: String, document: String, in db: Database
    ) throws {
        let existing = try LayerOverrideStore.overrides(db, projectId: project, documentId: document)
        for record in existing where overrides[record.layerId] == nil && record.visible != nil {
            // Back to the document default; a lock override on the same layer stays.
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: project, documentId: document, layerId: record.layerId,
                visible: nil, locked: record.locked
            ))
        }
        let locks = Dictionary(uniqueKeysWithValues: existing.map { ($0.layerId, $0.locked) })
        for (layerId, visible) in overrides {
            try LayerOverrideStore.upsert(db, LayerOverrideRecord(
                projectId: project, documentId: document, layerId: layerId,
                visible: visible, locked: locks[layerId] ?? nil
            ))
        }
    }
}
