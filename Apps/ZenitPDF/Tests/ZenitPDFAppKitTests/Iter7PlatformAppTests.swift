import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 7, persistence-services-platform in the app: the sync-conflict check looks in
/// the project's folder in the sandboxed application (X-049), and a drawing-file scale on a
/// `/UserUnit` sheet is named by the ratio it applies (X-052).
@MainActor
@Suite("Iteration 7 — platform in the app", .appTierSerialised, .serialized)
struct Iter7PlatformAppTests {

    private static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iter7-platform-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A one-page PDF of `pageEntries` (extra page dictionary entries) and a stroked line.
    private static func writePDF(in directory: URL, name: String, pageEntries: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let content = "1 w 0 0 0 RG 72 72 m 572 72 l S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1191 842] /Contents 4 0 R \(pageEntries) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(body.utf8).write(to: url)
        return url
    }

    // MARK: - X-052

    /// The sheet declares `/UserUnit 2` and a whole-page viewport of 1:200 per default unit
    /// (C = 200 × 0.0254 / 72 = 0.0705555… m per point). A preset is multiplied by the user unit,
    /// so the scale that measures the same is 1:100 — which the offer already said and applied.
    /// Old output: the applied scale was named "1:200 from the drawing file" while it read 1:100.
    @Test("X-052: a drawing-file scale on a /UserUnit 2 sheet is named by the ratio it applies")
    func userUnitSheetScaleIsNamedByItsRatio() async throws {
        let folder = try Self.scratch("x052")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = try Self.writePDF(in: folder, name: "Large format.pdf", pageEntries:
            "/UserUnit 2 /VP [<< /Type /Viewport /BBox [0 0 1191 842] /Measure << /Type /Measure /Subtype /RL /R (1:200) "
            + "/X [<< /Type /NumberFormat /U (m) /C 0.0705555555556 >>] >> >>]")
        let harness = try await Fix2Harness.make("unused.pdf", calibrate: false, fixture: pdf)
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        #expect(page.userUnit == 2)
        #expect(await AppTestSupport.wait { harness.core.document.warnings.contains { $0.title == "The drawing file says 1:100." } })
        let offer = try #require(harness.core.document.warnings.first { $0.title == "The drawing file says 1:100." })
        #expect(offer.actionTitle == "Apply 1:100")

        #expect(harness.document.handleDrawingFileScaleAction(offer.id))
        #expect(await AppTestSupport.wait { harness.core.document.warnings.allSatisfy { $0.id != offer.id } })
        let scale = try #require(await harness.core.session.scale(onPage: page.id))
        #expect(scale.label == "1:100 from the drawing file", "old: \"1:200 from the drawing file\"")
        // 500 pt on a /UserUnit 2 sheet is 1 000/72 in on paper; at 1:100 that is
        // 500 × 2 × 0.0254 / 72 × 100 = 35.2777… m, which is the viewport's 500 × 0.0705555… m.
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 72, y: 72), PDFPoint(x: 572, y: 72)])
        }
        let metres = try #require(await harness.core.session.markup(record.id)?.measurement?.values[.planLength]?.value)
        #expect(abs(NSDecimalNumber(decimal: metres).doubleValue - 500 * 2 * 0.0254 / 72 * 100) < 1e-9)
    }

    // MARK: - X-049

    /// A saved, closed project in its own folder, with a sync client's conflicted copy beside it.
    private static func projectWithConflictCopy(_ label: String) async throws -> (folder: URL, package: URL, sibling: String) {
        let folder = try scratch(label)
        let pdf = try writePDF(in: folder, name: "Source.pdf", pageEntries: "")
        let package = folder.appendingPathComponent("Block C.zpdfproj", isDirectory: true)
        let project = try await ProjectPackage.create(at: package, displayName: "Block C", originalPDF: pdf)
        _ = try await project.save()
        try await project.close()
        let sibling = "Block C (Mac-B's conflicted copy).zpdfproj"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(sibling), withIntermediateDirectories: true)
        try Data(sibling.utf8).write(to: folder.appendingPathComponent(sibling).appendingPathComponent("manifest.json"))
        return (folder, package, sibling)
    }

    /// The open path itself, with every prompt injected and the folder listing refused unless
    /// it runs inside a kept grant — what the sandbox does to a process holding a grant for the
    /// package only.
    private final class Run {
        var reports: [(copies: [String], versions: Int, folderChecked: Bool)] = []
    }

    private static func pipeline(_ run: Run, container: URL) -> DocumentLoadPipeline {
        var pipeline = DocumentLoadPipeline(
            request: .init(url: nil, mode: .project, promptURL: nil, displayName: nil, undoManager: UndoManager(),
                           toolPresetContainer: ToolPresetContainerStore(directory: container)),
            isAbandoned: { false },
            claimSearchIndexKey: { digest, _ in digest }
        )
        pipeline.reportSyncConflicts = { copies, versions, _ in
            run.reports.append((copies, versions, SharedStoragePrompt.conflictFolderChecked))
        }
        pipeline.askRecovery = { _, _ in .discard }
        pipeline.askForeignSession = { _, _ in .openReadOnly }
        return pipeline
    }

    private static func withSandboxedFolder<T>(synced: Bool, _ body: () async throws -> T) async rethrows -> T {
        let previous = (ConflictFolderAccess.defaultsOverride, ConflictFolderAccess.listing, ConflictFolderAccess.isInSyncedLocation)
        ConflictFolderAccess.defaultsOverride = ZPDFInMemoryDefaults()
        ConflictFolderAccess.listing = { folder, route in
            guard route == .throughGrant else { throw CocoaError(.fileReadNoPermission) }
            return try SyncConflictScanner.listFolder(folder)
        }
        ConflictFolderAccess.isInSyncedLocation = { _ in synced }
        ZenitModalPresenter.reset()
        defer {
            (ConflictFolderAccess.defaultsOverride, ConflictFolderAccess.listing, ConflictFolderAccess.isInSyncedLocation) = previous
            ZenitModalPresenter.reset()
        }
        return try await body()
    }

    /// Old output: `conflictCopyNames(besides:)` read the refused listing as an empty folder, so
    /// the open reported nothing and never asked — the sibling copy went unmentioned.
    @Test("X-049: a refused folder is asked for once, and its conflict copy is then reported")
    func refusedFolderIsAskedForAndReported() async throws {
        let project = try await Self.projectWithConflictCopy("x049-ask")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: true) {
            var panels: [ZenitModalRequest] = []
            ZenitModalPresenter.handler = { request in
                panels.append(request)
                return request.kind == .openPanel ? .urls([project.folder]) : .dismissed
            }
            let run = Run()
            let opened = try await Self.pipeline(run, container: project.folder.appendingPathComponent("tools")).openProjectPackage(at: project.package)
            try await opened.package.close()
            #expect(opened.conflictFolderChecked)
            #expect(panels.map(\.identifier) == [ConflictFolderAccess.openPanelIdentifier])
            #expect(panels.first?.buttons == ["Allow Access"])
            #expect(run.reports.map(\.copies) == [[project.sibling]])
            #expect(run.reports.first?.folderChecked == true)

            // The grant is kept: the next open is checked without asking.
            let again = try await Self.pipeline(run, container: project.folder.appendingPathComponent("tools")).openProjectPackage(at: project.package)
            try await again.package.close()
            #expect(panels.count == 1, "asked again for a folder already granted")
            #expect(run.reports.map(\.copies) == [[project.sibling], [project.sibling]])
        }
    }

    @Test("X-049: a declined folder is not asked about again, and the notice says it was not checked")
    func declinedFolderIsAskedOnceAndSaidUnchecked() async throws {
        let project = try await Self.projectWithConflictCopy("x049-decline")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: true) {
            var panels = 0
            ZenitModalPresenter.handler = { request in
                if request.kind == .openPanel { panels += 1 }
                return .dismissed
            }
            for _ in 0..<2 {
                #expect(await ConflictFolderAccess.scanAskingOnce(besides: project.package) == .folderNotChecked)
            }
            #expect(panels == 1, "a folder is asked about once")
            #expect(!ConflictFolderAccess.shouldAsk(besides: project.package))
        }
        let unchecked = SharedStoragePrompt.conflictText(copyNames: [], unresolvedVersions: 1, folderChecked: false)
        #expect(unchecked.contains("The project’s folder was not checked for copies: Zenit PDF has no access to it."))
        #expect(!SharedStoragePrompt.conflictText(copyNames: [], unresolvedVersions: 1).contains("not checked"))
    }

    @Test("X-049: a project outside a synced location is never asked about")
    func unsyncedFolderIsNotAsked() async throws {
        let project = try await Self.projectWithConflictCopy("x049-local")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: false) {
            ZenitModalPresenter.handler = { _ in .urls([project.folder]) }
            #expect(await ConflictFolderAccess.scanAskingOnce(besides: project.package) == .folderNotChecked)
            #expect(ZenitModalPresenter.recorded.isEmpty)
        }
    }

    /// The other copy is outside the package's grant: it is copied inside the folder grant's scope.
    @Test("X-049: the other copy is read inside the scope of the folder's grant")
    func otherCopyIsReadInsideTheGrant() async throws {
        let project = try await Self.projectWithConflictCopy("x049-copy")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: true) {
            ZenitModalPresenter.handler = { _ in .urls([project.folder]) }
            #expect(await ConflictFolderAccess.requestAccess(besides: project.package))
            var scopes: [String] = [], open = 0
            let previous = (ConflictFolderAccess.startAccessing, ConflictFolderAccess.stopAccessing, SyncedFolderSafety.otherCopiesFolder)
            defer { (ConflictFolderAccess.startAccessing, ConflictFolderAccess.stopAccessing, SyncedFolderSafety.otherCopiesFolder) = previous }
            ConflictFolderAccess.startAccessing = { scopes.append(ConflictFolderAccess.key($0)); open += 1; return true }
            ConflictFolderAccess.stopAccessing = { _ in open -= 1 }
            let copies = project.folder.appendingPathComponent("copies", isDirectory: true)
            SyncedFolderSafety.otherCopiesFolder = { copies }

            let copy = try #require(SyncedFolderSafety.copyOfOtherVersion(of: project.package, siblingNames: [project.sibling]))
            #expect(copy.lastPathComponent == "Block C (other version).zpdfproj")
            #expect(String(decoding: try Data(contentsOf: copy.appendingPathComponent("manifest.json")), as: UTF8.self) == project.sibling)
            #expect(scopes == [ConflictFolderAccess.key(project.folder)])
            #expect(open == 0, "the scope is left again")
        }
    }

    // MARK: - X-049 re-fix: the open says "not checked" with nothing else to report

    /// Opens the project as the application does, through a document.
    private static func openDocument(_ package: URL) async throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.projectPackage != nil })
        return document
    }

    private static func folderNote(_ document: ZenitPDFProjectDocument) -> AppWarning? {
        document.core?.document.warnings.first { $0.actionTitle == "Allow Access…" }
    }

    /// A project outside the locations that are asked about, the sandbox refusing its folder,
    /// and no versions kept by a sync service: the conflict notice has nothing to show, so it
    /// is not shown — and the tray says the folder was not checked, without a modal. Allow
    /// Access… asks, the grant is kept, the copy beside the project is reported, the note goes.
    /// Old output: no notice, no note — the same as a folder with no copies in it.
    @Test("X-049: an open that could not look in the folder says so in the tray, with no versions and nothing asked")
    func uncheckedFolderIsSaidInTheTray() async throws {
        let project = try await Self.projectWithConflictCopy("x049-tray")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: false) {
            #expect(SyncConflictScanner.unresolvedVersionCount(at: project.package) == 0)
            ZenitModalPresenter.handler = { request in
                switch request.kind {
                case .openPanel: return .urls([project.folder])
                default: return .button(2)   // the conflict notice: Later
                }
            }
            let document = try await Self.openDocument(project.package)
            defer { document.close() }
            let note = try #require(Self.folderNote(document), "the open said nothing about the folder it could not read")
            #expect(note.title == "The project’s folder was not checked for sync conflict copies.")
            #expect(note.message.contains("“Block C.zpdfproj”") && note.message.contains(project.folder.lastPathComponent))
            #expect(note.severity == .info && note.isDismissible)
            #expect(ZenitModalPresenter.recorded.isEmpty, "an unsynced folder is not asked about with a modal")

            // The note's action, through the window's own warning-action wiring.
            let shell = try #require(document.shell)
            shell.onWarningAction?(note)
            #expect(await AppTestSupport.wait { Self.folderNote(document) == nil }, "the note stayed after the folder was granted")
            #expect(await AppTestSupport.wait { ZenitModalPresenter.recorded.count == 2 })
            #expect(ZenitModalPresenter.recorded.map(\.identifier)
                == [ConflictFolderAccess.openPanelIdentifier, SyncedFolderSafety.conflictChoiceIdentifier])
            let notice = try #require(ZenitModalPresenter.recorded.last)
            #expect(notice.detail.contains(project.sibling), "\(notice.detail)")
            #expect(!notice.detail.contains("not checked"), "\(notice.detail)")
            #expect(ConflictFolderAccess.grantedFolder(covering: project.folder) != nil)
        }
    }

    /// The synced case, declined: asked once at open, the tray says the folder was not checked
    /// (nothing else to report), and declining Allow Access… again keeps the note — still true.
    @Test("X-049: a folder declined at open is said unchecked in the tray, and a second decline keeps the note")
    func declinedFolderIsSaidInTheTray() async throws {
        let project = try await Self.projectWithConflictCopy("x049-tray-decline")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try await Self.withSandboxedFolder(synced: true) {
            ZenitModalPresenter.handler = { _ in .dismissed }
            let document = try await Self.openDocument(project.package)
            defer { document.close() }
            #expect(ZenitModalPresenter.recorded.map(\.identifier) == [ConflictFolderAccess.openPanelIdentifier])
            let note = try #require(Self.folderNote(document), "a declined folder was passed off as no copies")

            #expect(document.shell?.onWarningAction != nil)
            document.shell?.onWarningAction?(note)
            #expect(await AppTestSupport.wait { ZenitModalPresenter.recorded.count == 2 })
            #expect(ZenitModalPresenter.recorded.map(\.kind) == [.openPanel, .openPanel], "Allow Access… asks even after a decline")
            try await Task.sleep(for: .milliseconds(100))
            #expect(Self.folderNote(document)?.id == note.id, "a declined Allow Access… took the note down")
            #expect(ConflictFolderAccess.grantedFolder(covering: project.folder) == nil)
        }
    }

    /// A stale bookmark resolves but will stop resolving: it is replaced by a fresh one made
    /// inside its own scope, once. Old output: the stale bookmark was kept, and the grant was
    /// lost the day it stopped resolving.
    @Test("X-049: a stale folder bookmark is replaced by one made inside its scope")
    func staleBookmarkIsRefreshed() throws {
        let folder = try Self.scratch("x049-stale")
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = (ConflictFolderAccess.defaultsOverride, ConflictFolderAccess.resolveBookmark, ConflictFolderAccess.makeBookmark,
                        ConflictFolderAccess.startAccessing, ConflictFolderAccess.stopAccessing)
        defer {
            (ConflictFolderAccess.defaultsOverride, ConflictFolderAccess.resolveBookmark, ConflictFolderAccess.makeBookmark,
             ConflictFolderAccess.startAccessing, ConflictFolderAccess.stopAccessing) = previous
        }
        let defaults = ZPDFInMemoryDefaults()
        ConflictFolderAccess.defaultsOverride = defaults
        let old = Data("old bookmark".utf8), fresh = Data("fresh bookmark".utf8)
        defaults.encode([ConflictFolderAccess.key(folder): old], forKey: ConflictFolderAccess.grantsKey)
        ConflictFolderAccess.resolveBookmark = { data in
            data == old ? (folder, true) : data == fresh ? (folder, false) : nil
        }
        var open = 0, madeInsideScope: [Bool] = []
        ConflictFolderAccess.startAccessing = { _ in open += 1; return true }
        ConflictFolderAccess.stopAccessing = { _ in open -= 1 }
        ConflictFolderAccess.makeBookmark = { _ in madeInsideScope.append(open > 0); return fresh }

        let inner = folder.appendingPathComponent("Sub", isDirectory: true)
        #expect(ConflictFolderAccess.grantedFolder(covering: inner).map(ConflictFolderAccess.key) == ConflictFolderAccess.key(folder))
        #expect(ConflictFolderAccess.storedGrants == [ConflictFolderAccess.key(folder): fresh])
        #expect(madeInsideScope == [true])
        #expect(open == 0, "the stale bookmark's scope is left again")

        // Fresh now: resolved without another bookmark.
        #expect(ConflictFolderAccess.grantedFolder(covering: folder) != nil)
        #expect(madeInsideScope.count == 1)
    }
}
