import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// CR-3: a foreign project's legacy `My Tools` rows go back into the project on save.
///
/// A package written before the container store existed carries the *author's* personal
/// presets. On a machine that already has a personal library they are not adopted, only
/// listed under `My Tools` for this project. `save` then split the merged list by panel, so the
/// next save wrote a stranger's presets into the person's container library and dropped them
/// from the package that owned them.
@Suite("Legacy My Tools rows stay with their project")
struct ToolPresetLegacyRoutingTests {

    private func workspace(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenitLegacyRouting-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func preset(_ name: String, panel: ToolLibraryPanel, id: UUID = UUID()) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            schemaVersion: 1,
            name: name,
            category: "Concrete",
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.5, blue: 0.9, alpha: 1),
            defaultSubject: name,
            displayLengthUnit: .metre,
            sortIndex: 0
        )
    }

    @Test("A stranger's un-adopted legacy rows are saved back into the package, never into the container")
    func legacyRowsRouteBackToThePackage() async throws {
        let directory = try workspace("route-back")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        // This machine already has a personal library, so nothing is adopted.
        let mine = preset("Mine", panel: .myTools)
        try await container.write([mine])

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Stranger.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Stranger", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }
        let stranger = preset("A stranger's tool", panel: .myTools)
        let job = preset("The job's tool", panel: .projectTools)
        try await ToolPresetArchive.write([stranger, job], into: package)

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(library.adoptedLegacyCount == 0)
        #expect(library.legacyProjectPresetIDs == [stranger.id])
        #expect(library.presets.map(\.name).sorted() == ["A stranger's tool", "Mine", "The job's tool"])

        // The panel hands the merged list back exactly as it listed it.
        try await ToolPresetLibraryStore.save(
            library.presets,
            package: package,
            container: container,
            legacyProjectPresetIDs: library.legacyProjectPresetIDs
        )

        // Old output: container == ["A stranger's tool", "Mine"], package == ["The job's tool"].
        #expect(try await container.read()?.map(\.name) == ["Mine"])
        let stored = try await ToolPresetArchive.read(from: package)
        #expect(stored.map(\.name).sorted() == ["A stranger's tool", "The job's tool"])
        // Still a legacy `My Tools` row inside the package, so the next open lists it the same way.
        #expect(stored.first { $0.id == stranger.id }?.panel == .myTools)
    }

    @Test("A caller that did not carry the ids from load still routes legacy rows back")
    func routingHoldsWithoutTheLoadedIDs() async throws {
        let directory = try workspace("derived")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ToolPresetContainerStore(
            directory: directory.appendingPathComponent("Container", isDirectory: true)
        )
        try await container.write([preset("Mine", panel: .myTools)])

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let packageURL = directory.appendingPathComponent("Stranger2.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Stranger2", originalPDF: fixture.url
        )
        defer { Task { try? await package.close() } }
        let stranger = preset("A stranger's tool", panel: .myTools)
        try await ToolPresetArchive.write([stranger], into: package)

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        // The app's existing call site passes no ids; the package's own rows decide.
        try await ToolPresetLibraryStore.save(library.presets, package: package, container: container)

        // Old output: container == ["A stranger's tool", "Mine"], package == [].
        #expect(try await container.read()?.map(\.name) == ["Mine"])
        #expect(try await ToolPresetArchive.read(from: package).map(\.name) == ["A stranger's tool"])
    }

    @Test("Adopted legacy rows are the person's: they stay in the container and leave the package")
    func adoptedRowsBelongToTheContainer() async throws {
        let directory = try workspace("adopted")
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
        let old = preset("Old personal tool", panel: .myTools)
        try await ToolPresetArchive.write([old], into: package)
        #expect(await container.exists() == false)

        let library = await ToolPresetLibraryStore.load(package: package, container: container)
        #expect(library.adoptedLegacyCount == 1)
        #expect(library.legacyProjectPresetIDs.isEmpty)

        try await ToolPresetLibraryStore.save(library.presets, package: package, container: container)
        #expect(try await container.read()?.map(\.name) == ["Old personal tool"])
        #expect(try await ToolPresetArchive.read(from: package).isEmpty)
    }
}
