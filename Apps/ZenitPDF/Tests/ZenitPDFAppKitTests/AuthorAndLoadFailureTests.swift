import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// A load failure is diagnosed before it is worded — a file this
/// process cannot READ is a permissions problem with a Grant Access offer, never
/// "damaged" with a repair offer that would fail the same way.
@MainActor
@Suite(.appTierSerialised)
struct LoadFailureDiagnosisTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-diagnosis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("An unreadable PDF is diagnosed as a permissions problem, not damage")
    func unreadableIsNotDamaged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handle = try ZPDFFixtures.make(.titleBlockSheet, in: directory)
        let anyError = ZenitDocumentError.documentNotReady

        // Readable and structurally fine: were it to fail, it would earn the repair path.
        #expect(ZenitPDFProjectDocument.diagnoseLoadFailure(for: handle.url, error: anyError) == .damaged)

        // The same file with read permission withdrawn: the diagnosis flips, and the
        // repair offer — which would fail exactly the way the open did — is withdrawn too.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: handle.url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: handle.url.path)
        }
        #expect(ZenitPDFProjectDocument.diagnoseLoadFailure(for: handle.url, error: anyError) == .unreadable)
        #expect(!DamagedDrawingRepair.canOffer(for: handle.url, afterLoadFailure: anyError),
                "a file that cannot be read must not be offered for repair")
    }

    @Test("Damage and everything else keep their existing classifications")
    func damagedAndPlainClassifications() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let anyError = ZenitDocumentError.documentNotReady

        let broken = try ZPDFFixtures.make(.brokenXref, in: directory)
        #expect(ZenitPDFProjectDocument.diagnoseLoadFailure(for: broken.url, error: anyError) == .damaged)

        let gone = directory.appendingPathComponent("missing.pdf")
        #expect(ZenitPDFProjectDocument.diagnoseLoadFailure(for: gone, error: anyError) == .plain)

        let package = directory.appendingPathComponent("Tower.zpdfproj")
        #expect(ZenitPDFProjectDocument.diagnoseLoadFailure(for: package, error: anyError) == .plain)
    }
}

/// The author name at the app tier: the first-run prompt's decision logic and the
/// Settings ▸ General ▸ Author name field, both against a scratch defaults suite.
@MainActor
@Suite("Author identity app surfaces", .appTierSerialised, .serialized)
struct AuthorSurfaceTests {

    private func withScratchDefaults(_ body: @MainActor () throws -> Void) throws {
        // `removePersistentDomain` empties the domain and leaves the plist: 1 108 of the
        // 2 547 empty `zenit*` files measured in a development machine's Preferences folder on
        // 2026-08-25 came from this one helper. `ScratchDefaults` removes both.
        try ScratchDefaults.with(prefix: "zenit-author-app-tests") { scratch, _ in
            let previous = AuthorIdentity.defaults
            AuthorIdentity.defaults = scratch
            defer { AuthorIdentity.defaults = previous }
            try body()
        }
    }

    @Test("Keeping the pre-filled name is one keystroke; skipping keeps the default silently")
    func firstRunPromptOutcomes() throws {
        try withScratchDefaults {
            #expect(AuthorIdentity.needsFirstRunPrompt)

            // Enter on the pre-filled field: the machine default stays a live default,
            // not a frozen copy, and the question is answered.
            AuthorNamePrompt.commit(enteredName: AuthorIdentity.machineDefault, skipped: false)
            #expect(AuthorIdentity.current() == AuthorIdentity.machineDefault)
            #expect(AuthorIdentity.defaults.string(forKey: AuthorIdentity.defaultsKey) == nil)
            #expect(!AuthorIdentity.needsFirstRunPrompt, "asked once, ever")
        }
        try withScratchDefaults {
            // A typed name wins.
            AuthorNamePrompt.commit(enteredName: "Kalkylatorn", skipped: false)
            #expect(AuthorIdentity.current() == "Kalkylatorn")
            #expect(!AuthorIdentity.needsFirstRunPrompt)
        }
        try withScratchDefaults {
            // Skip: whatever was typed is ignored, the default stays, the question is spent.
            AuthorNamePrompt.commit(enteredName: "Ignored", skipped: true)
            #expect(AuthorIdentity.current() == AuthorIdentity.machineDefault)
            #expect(!AuthorIdentity.needsFirstRunPrompt)
        }
    }

    @Test("Settings ▸ General edits the author name; an emptied field restores the default")
    func settingsFieldRoundTrips() throws {
        try withScratchDefaults {
            let settings = ZenitSettingsWindowController.shared
            settings.authorField.stringValue = "Anbudsavdelningen"
            settings.commitAuthorName()
            #expect(AuthorIdentity.current() == "Anbudsavdelningen")

            settings.authorField.stringValue = ""
            settings.commitAuthorName()
            #expect(AuthorIdentity.current() == AuthorIdentity.machineDefault)
            #expect(settings.authorField.stringValue == AuthorIdentity.machineDefault,
                    "the field shows the name actually in force")
        }
    }

    @Test("The application menu carries Settings… at ⌘, targeting the settings window")
    func settingsMenuItemExists() throws {
        let bar = ZenitMenuBar.make()
        let appMenu = try #require(bar.items.first?.submenu)
        let settings = try #require(appMenu.items.first { $0.keyEquivalent == "," })
        #expect(settings.title.hasPrefix("Settings"))
        #expect(settings.target === ZenitSettingsWindowController.shared)
    }
}

/// The committed measurement style at the canvas boundary: the stored measurement ink reaches the
/// drawable scene — stroke and the 20 % fill — instead of being re-derived or defaulted.
@MainActor
@Suite(.appTierSerialised)
struct CommittedInkSceneTests {

    @Test("The scene carries the stored ink stroke and low-alpha fill of a committed area")
    func sceneCarriesStoredInk() throws {
        let ink = AppMeasurementToolPresenter.measurementInk
        let fill = AppMeasurementToolPresenter.measurementFill(for: ink)
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Area",
            author: "test",
            style: MarkupStyle(color: ink, fill: fill),
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
        let shapes = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: pageID.rawValue)
        let shape = try #require(shapes.first)
        #expect(abs(shape.color.red - ink.red) < 0.001)
        #expect(abs(shape.color.green - ink.green) < 0.001)
        #expect(abs(shape.color.blue - ink.blue) < 0.001)
        let sceneFill = try #require(shape.fill, "the stored fill must reach the scene")
        // 20 %: the fill alpha of the 2026-09-23 default (design round d7; was 18 %).
        #expect(abs(sceneFill.alpha - 0.20) < 0.001)
        #expect(shape.strokes.contains { $0.closed && $0.filled }, "a closed area fills")
    }
}
