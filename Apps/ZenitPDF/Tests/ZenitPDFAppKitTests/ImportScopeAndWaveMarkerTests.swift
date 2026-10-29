import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Three pieces of wiring: the interchange reader that had no caller, the second tool preset
/// scope, and the convention that records who holds the working tree.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ImportScopeAndWaveMarkerTests {

    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZenitPDFAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Apps/ZenitPDF
        .deletingLastPathComponent()   // Apps
        .deletingLastPathComponent()   // repository root

    // MARK: - A ledger built through the shipping engines

    private func makeLedger(subjects: [String]) async throws -> AppCoreEnvironment {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, subject) in subjects.enumerated() {
            let width = Double(60 + index * 13)
            try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: subject,
                author: "test",
                geometry: MeasurementGeometry(
                    pageID: page.id,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0),
                        PDFPoint(x: width, y: 0),
                        PDFPoint(x: width, y: 80.5),
                        PDFPoint(x: 0, y: 80.5)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            )))
        }
        await environment.ledger.refresh()
        return environment
    }

    // MARK: - 1. The interchange reader now has a caller, and the round trip closes

    @Test("File ▸ Import Zenit JSON… exists in the File menu and routes to the application command")
    func importCommandIsInTheMenuBar() throws {
        let bar = ZenitMenuBar.make()
        var found: NSMenuItem?
        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            for entry in submenu.items
            where entry.representedObject as? String == ZenitAppCommand.importLedgerJSON.rawValue {
                #expect(submenu.title == ZPDFCommandGroup.file.displayName)
                found = entry
            }
        }
        let item = try #require(found, "the interchange reader still has no entry point")
        #expect(item.title.contains("Zenit JSON"))
        #expect(item.action == #selector(ZenitCommandResponding.performZenitCommand(_:)))
    }

    @Test("The import panel accepts exactly what the export dialog writes")
    func importPanelMatchesTheExportFormat() {
        let panel = ZenitJSONImport.makeOpenPanel()
        #expect(panel.allowedContentTypes == [ExportAccessoryView.Format.zenitJSON.contentType])
        #expect(panel.allowsMultipleSelection == false)
        #expect(panel.canChooseDirectories == false)
        #expect(ExportAccessoryView.Format.zenitJSON.fileExtension == "zpdfjson")
    }

    @Test("Export a project, import it back, and every digit is the digit that went out")
    func roundTripThroughTheShippingPath() async throws {
        let core = try await makeLedger(subjects: ["Slab on grade", "Slab on grade", "Parapet"])
        #expect(!core.ledger.isEmpty)

        // The bytes the export dialog would write, through the same two calls it makes.
        let ledger = try await ProjectWindowController.interchange(
            core: core,
            documentName: "Round Trip",
            scaleDescription: core.snapshot.firstPageScale?.displayString,
            request: core.ledger.request
        )
        let bytes = ZenitJSONExporter().encode(ledger)

        // The bytes the import command would read.
        let outcome = try ZenitJSONImport.load(
            bytes, fileName: "Round Trip.zpdfjson", against: ledger
        )
        #expect(outcome.review.rowCount == core.ledger.rowCount)
        #expect(outcome.review.producerApplication == "Zenit PDF")

        let result = try #require(outcome.reconciliation)
        #expect(result.isExactMatch, "the round trip lost something: \(result.differences)")
        #expect(result.rowsIdentical == core.ledger.rowCount)
        #expect(result.rowsDiffering == 0)
        #expect(result.rowsOnlyInFile.isEmpty)
        #expect(result.rowsOnlyInLedger.isEmpty)

        // Digit for digit, stated as its own assertion rather than inferred from a verdict.
        let reimported = try ZenitJSONImporter().document(from: bytes)
        var compared = 0
        let left = ZenitLedgerReconciliation.flatten(ledger)
        let right = ZenitLedgerReconciliation.flatten(reimported)
        #expect(!left.isEmpty)
        for (id, row) in left {
            let other = try #require(right[id])
            for (a, b) in zip(row.cells, other.cells) {
                if case .number(let x) = a, case .number(let y) = b {
                    #expect(x.raw == y.raw)
                    #expect(x.display == y.display)
                    #expect(x.unit == y.unit)
                    compared += 1
                }
            }
        }
        #expect(compared > 0, "the fixture carried no quantities, so nothing was proved")

        // And the bytes themselves: re-encoding what came back reproduces the file.
        #expect(ZenitJSONExporter().encode(reimported) == bytes)
    }

    @Test("A malformed payload is refused with a reason and never reaches the domain model")
    func malformedPayloadIsRefused() async throws {
        let core = try await makeLedger(subjects: ["Slab"])
        let ledger = try await ProjectWindowController.interchange(
            core: core,
            documentName: "Hostile",
            scaleDescription: nil,
            request: core.ledger.request
        )
        let rowsBefore = core.ledger.rowCount

        let hostile: [(String, Data)] = [
            ("empty", Data()),
            ("not JSON", Data("<html>nope</html>".utf8)),
            ("wrong format", Data(#"{"format":"other","schemaVersion":1}"#.utf8)),
            ("future schema", Data(#"{"format":"zenit.ledger.export","schemaVersion":77}"#.utf8)),
            (
                "a quantity that is not a decimal",
                Data(
                    String(decoding: ZenitJSONExporter().encode(ledger), as: UTF8.self)
                        .replacingOccurrences(of: "\"raw\": \"", with: "\"raw\": \"x")
                        .utf8
                )
            )
        ]
        for (label, data) in hostile {
            #expect(throws: (any Error).self, "\(label) was accepted") {
                _ = try ZenitJSONImport.load(data, fileName: label, against: ledger)
            }
        }
        // Nothing an import touches can change the takeoff, because nothing it produces is
        // handed to a command. The ledger is the same ledger.
        await core.ledger.refresh()
        #expect(core.ledger.rowCount == rowsBefore)
    }

    @Test("The review sheet says what the file is, and says that nothing was imported into the project")
    func reviewSheetText() async throws {
        let core = try await makeLedger(subjects: ["Slab", "Wall"])
        let ledger = try await ProjectWindowController.interchange(
            core: core, documentName: "Review", scaleDescription: nil, request: core.ledger.request
        )
        let outcome = try ZenitJSONImport.load(
            ZenitJSONExporter().encode(ledger), fileName: "Review.zpdfjson", against: ledger
        )
        let copy = ZenitJSONImport.text(for: outcome)
        #expect(copy.title.contains("Review.zpdfjson"))
        #expect(copy.body.contains("Zenit PDF"))
        #expect(copy.body.contains("nothing in it is written into the open project"))
        #expect(copy.body.contains("every value identical"))
    }

    @Test("Reviewing a file with no project open says so instead of comparing against nothing")
    func reviewWithoutAProject() async throws {
        let core = try await makeLedger(subjects: ["Slab"])
        let ledger = try await ProjectWindowController.interchange(
            core: core, documentName: "Alone", scaleDescription: nil, request: core.ledger.request
        )
        let outcome = try ZenitJSONImport.load(
            ZenitJSONExporter().encode(ledger), fileName: "Alone.zpdfjson", against: nil
        )
        #expect(outcome.reconciliation == nil)
        let copy = ZenitJSONImport.text(for: outcome)
        #expect(!copy.body.contains("Compared with the ledger on screen"))
    }

    // MARK: - 2. Two scopes

    @Test("A test process never writes into the user's real tool library")
    func containerIsScratchedInATestProcess() async throws {
        let directory = await ZenitPDFProjectDocument.processToolPresetContainer.directory
        #expect(!directory.path.contains("Application Support"))
        #expect(directory.path.contains(NSTemporaryDirectory()) || directory.path.hasPrefix("/var")
            || directory.path.hasPrefix("/private"))
    }

    @Test("A test process never writes the user's real set-mode preference")
    func setModeDefaultsAreScratchedInATestProcess() async throws {
        // The seam existed and one test forgot to inject through it, so
        // `ToolSetModeStore.write` put {"myTools":"apply"} into the user's real preferences,
        // in the `swiftpm-testing-helper` domain, where it stayed. Every document opened
        // afterwards — in that process and in every later run on that machine — came up with
        // My Tools in Apply, which disarms both drawing families: `build-app-package.sh` was
        // red three times and no line of code under test had changed. The rule is enforced
        // here rather than remembered.
        let store = await ZenitPDFProjectDocument.processToolSetModeDefaults
        #expect(
            !(store is UserDefaults),
            "a test process may not write the real UserDefaults for set modes"
        )
        // And the shipping default really is the real one, so the product still remembers a
        // mode between launches — an isolation seam that also disabled the feature would be a
        // worse defect than the one it closed.
        #expect(await ZenitPDFProjectDocument.toolSetModeDefaultsOverride == nil)
        let key = await ToolSetModeStore.defaultsKey
        #expect(
            UserDefaults.standard.data(forKey: key) == nil,
            "this process has written the user's real set-mode preference"
        )
    }

    @Test("A personal preset is saved to the container and a project preset to the package")
    func documentSplitsPresetsByScope() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let container = ToolPresetContainerStore(directory: scratch)
        ZenitPDFProjectDocument.toolPresetContainerOverride = container
        defer { ZenitPDFProjectDocument.toolPresetContainerOverride = nil }

        let url = try AppTestSupport.writeFixturePDF(named: "Scopes A-101.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait(upTo: 60) { document.core != nil })
        let core = try #require(document.core)

        let mine = preset("Discipline standard", panel: .myTools)
        let theirs = preset("Cost code 03-30-00", panel: .projectTools)
        document.applyToolPresets([mine, theirs])
        #expect(core.toolLibrary.presets.count == 2)

        // The person's set lands in the container, whether or not this document has a package.
        //
        // The wait is for the expected *content*, not for a non-empty file: the container is
        // already non-empty by the time this runs, because opening a library that has never seen
        // the built-in set seeds and persists it (`DefaultToolSet`). Breaking on the first
        // non-empty read would race that write and read the six shipped tools back.
        var stored: [String] = []
        for _ in 0..<200 {
            stored = ((try? await container.read()) ?? [])?.map(\.name) ?? []
            if stored == ["Discipline standard"] { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(stored == ["Discipline standard"])

        // And the project's set does not: a `.zpdfproj` must not carry the estimator's library.
        if let package = document.projectPackage {
            var inPackage: [String] = []
            for _ in 0..<200 {
                inPackage = (try? await ToolPresetArchive.read(from: package))?.map(\.name) ?? []
                if !inPackage.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(inPackage == ["Cost code 03-30-00"])
        }
    }

    @Test("The panel a preset is listed under is the store it came from, for every panel")
    func panelAndScopeCannotDisagree() {
        for panel in ToolLibraryPanel.allCases {
            let sample = preset("x", panel: panel)
            let expected: ToolPresetScope = panel == .projectTools ? .project : .container
            #expect(ToolPresetScopeRule.scope(of: sample) == expected)
        }
    }

    private func preset(_ name: String, panel: ToolLibraryPanel) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            schemaVersion: 1,
            name: name,
            category: "Concrete",
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.3, green: 0.6, blue: 0.2, alpha: 1),
            defaultSubject: name,
            displayLengthUnit: .metre
        )
    }

    // MARK: - 3. Who holds the tree

    @Test("The wave-marker convention exists and every build gate consults it")
    func waveMarkerIsWiredIntoTheGates() throws {
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/wave-marker.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        // Every gate a workstream actually runs must consult the marker before it does anything.
        let gates = [
            "build-app-package.sh", "build-appcore-package.sh", "build-core-packages.sh",
            "build-io-packages.sh", "build-ui-packages.sh", "build-renderer-package.sh",
            "build-snap-package.sh", "verify-export.sh", "verify-snap-search-compare.sh",
            "acceptance-core-loop.sh", "build-app.sh", "verify-app-launches.sh"
        ]
        for gate in gates {
            let source = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/" + gate),
                encoding: .utf8
            )
            #expect(
                source.contains("wave-marker.sh\" check"),
                "\(gate) does not ask who holds the tree"
            )
        }

        // And it documents its own use, where anyone running it reads it first.
        let usage = try String(contentsOf: script, encoding: .utf8)
        #expect(usage.contains("Scripts/wave-marker.sh claim"))
        #expect(usage.contains("Scripts/wave-marker.sh release"))
        #expect(usage.contains("Scripts/wave-marker.sh check"))
    }

    @Test("A foreign marker warns and never fails; a stale one is removed rather than obeyed")
    func waveMarkerWarnsAndExpires() throws {
        let root = Self.repositoryRoot
        let markerDirectory = root.appendingPathComponent(".zenit-waves", isDirectory: true)
        try FileManager.default.createDirectory(
            at: markerDirectory, withIntermediateDirectories: true
        )
        let name = "apptest-\(UUID().uuidString.prefix(8))"

        func write(_ run: String, ageSeconds: Int) throws -> URL {
            let file = markerDirectory.appendingPathComponent("\(run).marker")
            let started = Int(Date().timeIntervalSince1970) - ageSeconds
            try """
            run=\(run)
            claimed_by_pid=1
            owner_pid=
            host=elsewhere
            started_epoch=\(started)
            started_iso=1970-01-01T00:00:00Z
            ttl_seconds=5400
            dirs=Apps/ZenitPDF
            """.write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        // Fresh: warned about, and the gate still runs.
        let fresh = try write("\(name)-fresh", ageSeconds: 5)
        defer { try? FileManager.default.removeItem(at: fresh) }
        let warned = try Self.runMarker(root: root, arguments: ["check", "Apps/ZenitPDF"])
        #expect(warned.status == 0, "a marker must never be able to redden a gate")
        #expect(warned.output.contains("another wave holds this tree"))
        #expect(warned.output.contains("\(name)-fresh"))
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        // Stale: expired by the next check, so a crashed run cannot wedge anything.
        let stale = try write("\(name)-stale", ageSeconds: 99_999)
        defer { try? FileManager.default.removeItem(at: stale) }
        let pruned = try Self.runMarker(root: root, arguments: ["check"])
        #expect(pruned.status == 0)
        #expect(pruned.output.contains("expiring \(name)-stale"))
        #expect(!FileManager.default.fileExists(atPath: stale.path))

        // Claim and release round-trip on a name of this test's own.
        let claimed = try Self.runMarker(
            root: root, arguments: ["claim", "\(name)-own", "Apps/ZenitPDF"]
        )
        #expect(claimed.status == 0)
        let own = markerDirectory.appendingPathComponent("\(name)-own.marker")
        #expect(FileManager.default.fileExists(atPath: own.path))
        let released = try Self.runMarker(root: root, arguments: ["release", "\(name)-own"])
        #expect(released.status == 0)
        #expect(!FileManager.default.fileExists(atPath: own.path))
    }

    private static func runMarker(
        root: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("Scripts/wave-marker.sh").path] + arguments
        process.currentDirectoryURL = root
        // No `ZENIT_WAVE`, so every marker on the tree reads as somebody else's.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZENIT_WAVE")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
