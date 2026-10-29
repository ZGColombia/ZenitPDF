import Foundation
import ZPDFPersistence
import ZPDFUIPresentation

/// Reads and writes the Tool Library across **both** of its stores.
///
/// One call site in the document instead of two, so the precedence rule
/// (``ToolPresetScopeRule``) is applied in one place and cannot be applied differently at open
/// and at save. Before this existed there was one store — the open project package — and
/// `My Tools` was written into whichever `.zpdfproj` happened to be in front of the person.
public enum ToolPresetLibraryStore {

    /// Loads the merged library for one open project.
    ///
    /// Total: it does not throw. A project must open even when the personal library is corrupt
    /// or the package's preset table is unreadable, so both failures degrade to *fewer presets
    /// and a stated reason* rather than to a document that will not open. The reason travels in
    /// ``ToolPresetLibrary/containerFailure`` for the caller to surface.
    ///
    /// - Parameters:
    ///   - package: the open project package, or `nil` in Quick PDF Mode, where there is no
    ///     package yet and the personal library is still the person's.
    ///   - container: the application-container store.
    public static func load(
        package: ProjectPackage?,
        container: ToolPresetContainerStore
    ) async -> ToolPresetLibrary {
        var containerPresets: [ToolPresetSummary] = []
        var containerFailure: String?
        var adopted = 0
        var legacyProjectPresetIDs: Set<UUID> = []

        do {
            containerPresets = try await container.read() ?? []
        } catch {
            containerFailure = String(describing: error)
        }

        guard let package else {
            return ToolPresetLibrary(
                presets: containerPresets,
                containerCount: containerPresets.count,
                projectCount: 0,
                containerFailure: containerFailure
            )
        }

        let stored = (try? await ToolPresetArchive.read(from: package)) ?? []
        var projectPresets = ToolPresetScopeRule.presets(stored, in: .project)
        let legacy = ToolPresetScopeRule.presets(stored, in: .container)

        // The one-time migration, and its guard.
        //
        // Packages written before the container store existed carry the person's `My Tools` rows
        // inside the project. Adopting them is right exactly once — on a machine that has never
        // had a personal library — and wrong every other time: a project that arrives by e-mail
        // must not merge a stranger's tools into yours. So the adoption turns on
        // `container.exists()`, which is false only before this machine's first write.
        if !legacy.isEmpty, containerFailure == nil, await !container.exists() {
            do {
                try await container.write(legacy)
                containerPresets = legacy
                adopted = legacy.count
            } catch {
                containerFailure = String(describing: error)
            }
        } else if !legacy.isEmpty {
            // Not adopted, and not thrown away either: they stay visible for this project only,
            // resolved under rule 2 like any other project-side row — and remembered by
            // identity, so the next save puts them back where they came from.
            projectPresets = ToolPresetScopeRule.merge(container: legacy, project: projectPresets)
            legacyProjectPresetIDs = Set(legacy.map(\.id))
        }

        let merged = ToolPresetScopeRule.merge(
            container: containerPresets, project: projectPresets
        )
        return ToolPresetLibrary(
            presets: merged,
            containerCount: containerPresets.count,
            projectCount: projectPresets.count,
            adoptedLegacyCount: adopted,
            containerFailure: containerFailure,
            legacyProjectPresetIDs: legacyProjectPresetIDs
        )
    }

    /// Writes a merged library back into the two stores it came from.
    ///
    /// Split by ``ToolPresetScopeRule``, so a `Project Tools` preset lands in the `.zpdfproj` and
    /// a `My Tools` preset lands in the container, whatever order the panel happened to hand
    /// them over in.
    ///
    /// Both writes are attempted even when the first fails, and the first error is rethrown
    /// afterwards: failing to save the project's set is not a reason to also lose the person's.
    ///
    /// # Legacy rows go back to the package
    ///
    /// A package written before the container store existed carries `My Tools` rows of its
    /// own. When this machine already had a personal library they were *not* adopted at open
    /// (see ``load(package:container:)``), only listed — and a save then split the merged list
    /// by panel, so a stranger's presets were written into the person's container library and
    /// dropped from the package that owned them (CR-3). Two things now keep them where they
    /// belong: `legacyProjectPresetIDs`, the identities ``load`` reported, and — so the rule
    /// holds even for a caller that did not carry them — the package's own container-scope rows
    /// that the container store does not hold. Either way the row is written back into the
    /// `.zpdfproj` and kept out of the container. A row the container *does* hold was adopted,
    /// and adopted rows are the person's.
    public static func save(
        _ presets: [ToolPresetSummary],
        package: ProjectPackage?,
        container: ToolPresetContainerStore,
        legacyProjectPresetIDs: Set<UUID> = []
    ) async throws {
        var firstFailure: (any Error)?

        var packageBound = legacyProjectPresetIDs
        if let package {
            let stored = (try? await ToolPresetArchive.read(from: package)) ?? []
            let legacy = Set(ToolPresetScopeRule.presets(stored, in: .container).map(\.id))
            if !legacy.isEmpty {
                let owned = Set(((try? await container.read()) ?? []).map(\.id))
                packageBound.formUnion(legacy.subtracting(owned))
            }
        }

        let containerRows = presets.filter {
            ToolPresetScopeRule.scope(of: $0) == .container && !packageBound.contains($0.id)
        }
        let packageRows = presets.filter {
            ToolPresetScopeRule.scope(of: $0) == .project || packageBound.contains($0.id)
        }

        do {
            try await container.write(containerRows)
        } catch {
            firstFailure = error
        }

        if let package {
            do {
                try await ToolPresetArchive.write(packageRows, into: package)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure { throw firstFailure }
    }
}
