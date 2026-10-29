import Foundation
import ZPDFUIPresentation

/// Where a tool preset is stored, and therefore whose it is.
///
/// Both scopes exist for one reason: *a discipline standard belongs to the estimator, a
/// project's cost codes belong to the project.* Until this
/// type existed the product had only the second half — every preset, including the personal set,
/// was written into whichever `.zpdfproj` happened to be open, which `ToolPresetArchive`'s own
/// header admitted.
public enum ToolPresetScope: String, Sendable, Hashable, CaseIterable, Codable {

    /// The person's own library, in the application container. It survives closing the project
    /// and follows the estimator from job to job. It does **not** travel inside a `.zpdfproj`,
    /// so sending a project to somebody else does not send them your tools.
    case container

    /// The project's library, inside the `.zpdfproj` package. It travels with the project, which
    /// is the entire point of a project set: the cost codes a job was measured against have to
    /// arrive with the job.
    case project

    /// A short label for the set, for anywhere that names a scope in words.
    public var displayName: String {
        switch self {
        case .container:
            return NSLocalizedString(
                "My Tools", comment: "Name of the tool preset set stored in the app container"
            )
        case .project:
            return NSLocalizedString(
                "Project Tools", comment: "Name of the tool preset set stored in the project"
            )
        }
    }
}

/// The single place that decides which store a preset belongs in, and which copy wins when both
/// stores hold one.
///
/// # The precedence rule, stated once
///
/// 1. **Scope is a function of the panel.** ``ToolLibraryPanel/projectTools`` is the project's
///    set; every other panel is the person's. There is no second source of truth and no per-
///    preset scope flag that could disagree with the panel a preset is listed under — which is
///    also how the panel *shows* which set a preset came from: the section header is the answer,
///    and it cannot lie, because the scope was read off it.
/// 2. **On a collision of identity, the project's copy wins for the project that is open.** Two
///    presets can share a `UUID` only when a project package was written before this rule
///    existed, or when the same preset was copied into a project deliberately. Either way the
///    copy inside the `.zpdfproj` is the one this project's markups were measured against, so it
///    is the one the open document sees. The container's copy is never modified by the
///    resolution and returns the moment another project is opened.
/// 3. **Order is preserved.** The container's presets keep their order, the project's keep
///    theirs, and the project's follow the container's. A merge that re-sorted would silently
///    renumber the number-key shortcuts of the first nine slots.
public enum ToolPresetScopeRule {

    /// Which store a panel's presets live in.
    public static func scope(for panel: ToolLibraryPanel) -> ToolPresetScope {
        switch panel {
        case .projectTools:
            return .project
        case .myTools, .recent, .favorites, .sequences, .countSymbols, .importedLibraries:
            return .container
        }
    }

    /// Which store one preset lives in.
    public static func scope(of preset: ToolPresetSummary) -> ToolPresetScope {
        scope(for: preset.panel)
    }

    /// The subset of a library that belongs in one store.
    public static func presets(
        _ presets: [ToolPresetSummary],
        in scope: ToolPresetScope
    ) -> [ToolPresetSummary] {
        presets.filter { ToolPresetScopeRule.scope(of: $0) == scope }
    }

    /// Merges the two stores under rule 2 and rule 3 above.
    ///
    /// - Parameters:
    ///   - container: what the application container holds — the person's sets.
    ///   - project: what the open `.zpdfproj` holds. May still contain container-scope rows on a
    ///     package written before the container store existed; those are kept, because dropping
    ///     a preset somebody made is not a migration, it is data loss.
    public static func merge(
        container: [ToolPresetSummary],
        project: [ToolPresetSummary]
    ) -> [ToolPresetSummary] {
        let projectIDs = Set(project.map(\.id))
        var merged = container.filter { !projectIDs.contains($0.id) }
        var seen = Set(merged.map(\.id))
        for preset in project where seen.insert(preset.id).inserted {
            merged.append(preset)
        }
        return merged
    }
}

/// One resolved Tool Library, and an account of where it came from.
///
/// The counts are not decoration: the panel and the app suite both need to be able to say *this
/// preset came from your library and that one came from the project*, and a merged array alone
/// cannot answer that after the fact.
public struct ToolPresetLibrary: Sendable, Hashable {

    /// The merged library, in the order the panel lists it.
    public let presets: [ToolPresetSummary]

    /// How many came from the application container.
    public let containerCount: Int

    /// How many came from the open project package.
    public let projectCount: Int

    /// How many container-scope presets were adopted out of a legacy package on this open.
    public let adoptedLegacyCount: Int

    /// Why the container store could not be read, when it could not. The project still opens —
    /// an unreadable personal library is a reason to warn, never a reason to refuse a document.
    public let containerFailure: String?

    /// Container-scope presets that live in the open package and were **not** adopted — a
    /// stranger's `My Tools`, in a project that arrived by e-mail.
    ///
    /// They are listed under `My Tools` for this project only, and they belong to the package:
    /// ``ToolPresetLibraryStore/save(_:package:container:legacyProjectPresetIDs:)`` routes them
    /// back into the `.zpdfproj` rather than into the person's library, which is where a save
    /// used to put them (CR-3).
    public let legacyProjectPresetIDs: Set<UUID>

    public init(
        presets: [ToolPresetSummary],
        containerCount: Int,
        projectCount: Int,
        adoptedLegacyCount: Int = 0,
        containerFailure: String? = nil,
        legacyProjectPresetIDs: Set<UUID> = []
    ) {
        self.presets = presets
        self.containerCount = containerCount
        self.projectCount = projectCount
        self.adoptedLegacyCount = adoptedLegacyCount
        self.containerFailure = containerFailure
        self.legacyProjectPresetIDs = legacyProjectPresetIDs
    }

    public static let empty = ToolPresetLibrary(
        presets: [], containerCount: 0, projectCount: 0
    )

    /// Which store one preset in this library came from, by identity.
    ///
    /// Answered from the panel, which is what rule 1 makes possible — and asserted in the app
    /// suite, so a future preset that claims one set and is stored in the other fails a gate
    /// rather than confusing a person.
    public func scope(of preset: ToolPresetSummary) -> ToolPresetScope {
        ToolPresetScopeRule.scope(of: preset)
    }
}
