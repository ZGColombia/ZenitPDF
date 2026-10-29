import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// The two preset scopes: a discipline standard belongs to the estimator, a
/// project's cost codes belong to the project.
@Suite("Tool preset scopes")
struct ToolPresetScopeTests {

    // MARK: - Fixtures

    private func workspace(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenitToolScope-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func preset(
        _ name: String,
        panel: ToolLibraryPanel,
        id: UUID = UUID(),
        category: String = "Concrete",
        sortIndex: Int = 0
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            schemaVersion: 1,
            name: name,
            category: category,
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.5, blue: 0.9, alpha: 1),
            defaultSubject: name,
            displayLengthUnit: .metre,
            sortIndex: sortIndex
        )
    }

    // MARK: - The rule

    @Test("Scope is a function of the panel, so the panel a preset is listed under is the set it came from")
    func scopeFollowsPanel() {
        #expect(ToolPresetScopeRule.scope(for: .projectTools) == .project)
        for panel in ToolLibraryPanel.allCases where panel != .projectTools {
            #expect(
                ToolPresetScopeRule.scope(for: panel) == .container,
                "\(panel.rawValue) must be the person's, not the project's"
            )
        }
        // Every panel is decided. A new panel added to ZPDFUIPresentation without a scope would
        // stop compiling `scope(for:)`, which is the point of switching exhaustively there.
        #expect(ToolLibraryPanel.allCases.count == 7)
    }

    @Test("On a collision of identity the project's copy wins, and the container's is untouched")
    func projectWinsOnCollision() {
        let shared = UUID()
        let container = [preset("Personal", panel: .myTools, id: shared)]
        let project = [preset("Job", panel: .projectTools, id: shared)]
        let merged = ToolPresetScopeRule.merge(container: container, project: project)
        #expect(merged.count == 1)
        #expect(merged.first?.name == "Job")
        // Merging is a read: the array it was given is the array it still is.
        #expect(container.first?.name == "Personal")
    }

    @Test("Order is preserved: the container's set first, the project's after, neither re-sorted")
    func orderIsPreserved() {
        let container = [
            preset("A", panel: .myTools, sortIndex: 5),
            preset("B", panel: .myTools, sortIndex: 0)
        ]
        let project = [
            preset("C", panel: .projectTools, sortIndex: 9),
            preset("D", panel: .projectTools, sortIndex: 1)
        ]
        let merged = ToolPresetScopeRule.merge(container: container, project: project)
        #expect(merged.map(\.name) == ["A", "B", "C", "D"])
    }

    // MARK: - The container store

    @Test("A library written to the container is read back exactly, and the bytes are stable")
    func containerRoundTrip() async throws {
        let directory = try workspace("round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolPresetContainerStore(directory: directory)

        #expect(await store.exists() == false)
        #expect(try await store.read() == nil)

        let library = [
            preset("Exterior Wall", panel: .myTools, sortIndex: 0),
            preset("Slab", panel: .myTools, category: "Concrete", sortIndex: 1)
        ]
        try await store.write(library)
        #expect(await store.exists())
        #expect(try await store.read() == library)

        let first = try Data(contentsOf: await store.fileURL)
        try await store.write(library)
        let second = try Data(contentsOf: await store.fileURL)
        #expect(first == second, "two saves of one library must produce identical bytes")
    }

    @Test("A project preset handed to the container store is not written there")
    func containerRefusesProjectScope() async throws {
        let directory = try workspace("scope-filter")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolPresetContainerStore(directory: directory)
        try await store.write([
            preset("Mine", panel: .myTools),
            preset("The job's", panel: .projectTools)
        ])
        let stored = try await store.read()
        #expect(stored?.map(\.name) == ["Mine"])
    }

    @Test("A container file that is not a Zenit tool library is refused by name, not read as empty")
    func containerRefusesForeignFile() async throws {
        let directory = try workspace("foreign")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolPresetContainerStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"format":"something.else","schemaVersion":1,"presets":[]}"#.utf8)
            .write(to: await store.fileURL)
        await #expect(throws: ToolPresetContainerStore.StoreError.self) {
            _ = try await store.read()
        }
    }

    @Test("A container file from a future build is refused by version, never guessed at")
    func containerRefusesFutureVersion() async throws {
        let directory = try workspace("future")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolPresetContainerStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"format":"zenit.toolLibrary.container","schemaVersion":9,"presets":[]}"#.utf8)
            .write(to: await store.fileURL)
        let error = await #expect(throws: ToolPresetContainerStore.StoreError.self) {
            _ = try await store.read()
        }
        #expect(error == .unsupportedSchemaVersion(found: 9, supported: 1))
    }

    // MARK: - The two stores together

    @Test("Load merges both stores; save splits back into both")
    func loadAndSaveAcrossScopes() async throws {
        let directory = try workspace("both")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Scopes.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Scopes", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }

        let mine = preset("Discipline standard", panel: .myTools)
        let theirs = preset("Cost code 03-30-00", panel: .projectTools)
        try await ToolPresetLibraryStore.save(
            [mine, theirs], package: package, container: container
        )

        // Each store holds its own half and nothing else.
        #expect(try await container.read()?.map(\.name) == ["Discipline standard"])
        #expect(try await ToolPresetArchive.read(from: package).map(\.name) == ["Cost code 03-30-00"])

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(library.presets.map(\.name) == ["Discipline standard", "Cost code 03-30-00"])
        #expect(library.containerCount == 1)
        #expect(library.projectCount == 1)
        #expect(library.adoptedLegacyCount == 0)
        #expect(library.containerFailure == nil)
        #expect(library.scope(of: mine) == .container)
        #expect(library.scope(of: theirs) == .project)
    }

    @Test("The person's library survives a project that never existed — Quick PDF Mode has no package")
    func containerWithoutAPackage() async throws {
        let directory = try workspace("no-package")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(directory: directory)
        try await ToolPresetLibraryStore.save(
            [preset("Mine", panel: .myTools)], package: nil, container: container
        )
        let library = await ToolPresetLibraryStore.load(package: nil, container: container)
        #expect(library.presets.map(\.name) == ["Mine"])
        #expect(library.projectCount == 0)
    }

    @Test("A legacy package's personal presets are adopted once, on a machine that has no library yet")
    func legacyAdoption() async throws {
        let directory = try workspace("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Legacy.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Legacy", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }

        // A package written the old way: `My Tools` inside the project, because there was
        // nowhere else to put it.
        try await ToolPresetArchive.write(
            [preset("Old personal tool", panel: .myTools)], into: package
        )
        #expect(await container.exists() == false)

        let first = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(first.adoptedLegacyCount == 1)
        #expect(first.presets.map(\.name) == ["Old personal tool"])
        #expect(try await container.read()?.map(\.name) == ["Old personal tool"])
    }

    @Test("A second project's personal presets are NOT merged into a library that already exists")
    func adoptionHappensOnlyOnce() async throws {
        let directory = try workspace("no-second-adoption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        try await container.write([preset("Mine", panel: .myTools)])

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Stranger.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Stranger", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }
        try await ToolPresetArchive.write(
            [preset("A stranger's tool", panel: .myTools)], into: package
        )

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(library.adoptedLegacyCount == 0)
        // Visible for this project — nothing is thrown away — and the person's own library on
        // disk is exactly what it was. Opening somebody's project must not edit your tools.
        #expect(library.presets.map(\.name).sorted() == ["A stranger's tool", "Mine"])
        #expect(try await container.read()?.map(\.name) == ["Mine"])
    }

    @Test("An unreadable personal library reports a reason and still lets the project open")
    func unreadableContainerDegrades() async throws {
        let directory = try workspace("unreadable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Container", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not json at all".utf8).write(to: await container.fileURL)

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Degrade.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Degrade", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }
        try await ToolPresetArchive.write(
            [preset("The job's tool", panel: .projectTools)], into: package
        )

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(library.containerFailure != nil)
        #expect(library.presets.map(\.name) == ["The job's tool"])
        #expect(library.adoptedLegacyCount == 0)
    }
}
