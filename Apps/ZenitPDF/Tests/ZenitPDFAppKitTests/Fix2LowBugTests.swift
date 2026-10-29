import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Bug hunt 2, the low-severity app items that can be pinned without a live session.
@MainActor
@Suite(.appTierSerialised)
struct Fix2LowBugTests {

    private func source(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/\(relative)"),
            encoding: .utf8
        )
    }

    // MARK: - Canvas

    @Test("BH-881: releasing Space or the middle button rests on the armed verb's cursor, not an arrow")
    func panEndRestoresTheArmedCursor() async throws {
        let harness = try await Fix2Harness.make("BH881.pdf", calibrate: false)
        defer { harness.tearDown() }
        let pageView = harness.canvas.pageViewForTesting
        pageView.cursorKind = .draw
        #expect(pageView.restingCursor() === CanvasCursorKind.draw.nsCursor)
        pageView.isPanTool = true
        #expect(pageView.restingCursor() === NSCursor.openHand)
        // Old: keyUp and otherMouseUp both set `NSCursor.arrow`.
        #expect(!(try source("Canvas/CanvasPageView.swift")).contains("NSCursor.arrow.set()"))
    }

    @Test("BH-882: an arc with an absurd sweep draws at most one turn instead of trapping or hanging")
    func hugeSweepIsBounded() {
        let center = PDFPoint(x: 100, y: 100)
        // Old: 1e300 trapped on `Int(...)`; 1e12 asked for ~10^13 points.
        for sweep in [1e300, -1e12, .infinity, .nan] {
            let points = CanvasSceneBuilder.arcPoints(
                ArcGeometry(center: center, radius: 10, startAngle: 0, sweepAngle: sweep)
            )
            #expect(points.count <= 73, "sweep \(sweep) gave \(points.count) points")
        }
        let quarter = CanvasSceneBuilder.arcPoints(
            ArcGeometry(center: center, radius: 10, startAngle: 0, sweepAngle: .pi / 2)
        )
        #expect(abs(quarter.last!.x - 100) < 1e-9 && abs(quarter.last!.y - 110) < 1e-9)
    }

    @Test("BH-886: a layer toggle that changed annotations flushes the Navigator's cached images")
    func layerToggleFlushesNavigatorImages() async throws {
        let harness = try await Fix2Harness.make("BH886.pdf", calibrate: false)
        defer { harness.tearDown() }
        let revision = harness.shell.navigatorThumbnails.providerRevision
        harness.document.invalidateThumbnailsAfterLayerChange()
        // Old: nothing cleared the loader, so every drawn row kept the hidden annotations.
        #expect(harness.shell.navigatorThumbnails.providerRevision != revision
                || harness.shell.navigatorThumbnails.cachedBytes == 0)
        #expect(harness.document.layerThumbnailInvalidationCount == 1)
        #expect(try source("Document/ZenitPDFProjectDocument.swift")
            .contains("if changed > 0 { self.invalidateThumbnailsAfterLayerChange() }"))
    }

    // MARK: - Document

    @Test("BH-892: window restoration resolves a dropped file's bookmark like Open does")
    func restorationResolvesTheBookmark() throws {
        let original = URL(fileURLWithPath: "/Volumes/Gone/Plan.pdf")
        let resolved = URL(fileURLWithPath: "/private/tmp/Plan.pdf")
        let (target, release) = ZenitDocumentController.resolvedAccess(
            for: original, isReadable: { _ in false }, resolve: { _ in resolved }
        )
        #expect(target == resolved)
        #expect(release != nil)
        let (readable, none) = ZenitDocumentController.resolvedAccess(
            for: original, isReadable: { _ in true }, resolve: { _ in resolved }
        )
        #expect(readable == original && none == nil)
        // Old: `reopenDocument(for:withContentsOf:display:completionHandler:)` was not
        // overridden, so restoration never consulted the bookmark.
        #expect(try source("Document/ZenitDocumentController.swift")
            .contains("public override func reopenDocument("))
    }

    @Test("BH-897 / BH-898: an unreachable file keeps its bookmark; an undecodable store is set aside, not overwritten")
    func bookmarksSurviveOutagesAndFormatChanges() throws {
        try ScratchDefaults.with(prefix: "zenit-fix2-bookmarks") { defaults, _ in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zpdf-bm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("External.pdf")
            try Data("%PDF-1.4\n".utf8).write(to: file)
            DroppedFileBookmarks.remember(file, defaults: defaults)
            guard DroppedFileBookmarks.hasBookmark(forPath: file.path, defaults: defaults) else {
                // An unsandboxed test process may be refused a security-scoped bookmark; the
                // decision itself is still pinned below.
                #expect(!DroppedFileBookmarks.isPermanentResolveFailure(CocoaError(.fileNoSuchFile)))
                return
            }
            try FileManager.default.removeItem(at: file)
            _ = DroppedFileBookmarks.beginAccess(forPath: file.path, defaults: defaults)
            // Old: any resolve error removed the entry — an unmounted drive lost it for good.
            #expect(DroppedFileBookmarks.hasBookmark(forPath: file.path, defaults: defaults))
            #expect(DroppedFileBookmarks.isPermanentResolveFailure(CocoaError(.fileReadCorruptFile)))
            #expect(!DroppedFileBookmarks.isPermanentResolveFailure(CocoaError(.fileNoSuchFile)))

            // BH-898: a blob this build cannot decode.
            let alien = Data(#"[{"path":"/x","future":1}]"#.utf8)
            defaults.set(alien, forKey: DroppedFileBookmarks.defaultsKey)
            try Data("%PDF-1.4\n".utf8).write(to: file)
            DroppedFileBookmarks.remember(file, defaults: defaults)
            // Old: decoded as [] and the one new entry was written over every older bookmark.
            #expect(defaults.data(forKey: DroppedFileBookmarks.undecodableBackupKey) == alien)
        }
    }

    @Test("BH-894: a promoted cloud on the baseline page uses the baseline's bounds first")
    func promotedCloudUsesBaselineSpace() {
        let baseline = PDFRectValue(x: 10, y: 10, width: 50, height: 20)
        let comparison = PDFRectValue(x: 40, y: 12, width: 50, height: 20)
        let diff = CompareDiffSummary(
            id: UUID(), changeKind: .modified, pageLabel: "A-101",
            baselineBounds: baseline, comparisonBounds: comparison,
            areaInSquarePoints: 1000, confidence: 0.9
        )
        // Old: `comparisonBounds ?? baselineBounds` regardless of the page it lands on.
        #expect(ZenitPDFProjectDocument.cloudBounds(for: diff, placedOnBaseline: true) == baseline)
        #expect(ZenitPDFProjectDocument.cloudBounds(for: diff, placedOnBaseline: false) == comparison)
        var added = diff
        added.baselineBounds = nil
        #expect(ZenitPDFProjectDocument.cloudBounds(for: added, placedOnBaseline: true) == comparison)
    }

    // MARK: - Window and workflows

    @Test("BH-900: a failed extraction is named as a failure, not 'no vector geometry'")
    func symbolScheduleNamesTheFailure() {
        let note = ProjectWindowController.symbolScheduleExtractionFailureNote(
            CocoaError(.fileReadNoPermission)
        )
        // Old: every `try?` failure read "This page has no vector geometry to match symbols in."
        #expect(!note.contains("no vector geometry"))
        #expect(note.hasPrefix("Could not read this page's vector geometry"))
    }

    @Test("BH-902: two templates with one name are two rows, and the index names the right one")
    func repeatedTemplateNamesKeepTheirRows() {
        let names = ["Roofing", "Groundwork", "Roofing"]
        let popup = ProjectWindowController.makeTemplatePopup(names)
        // Old: `addItems(withTitles:)` dropped a repeat — two rows for three templates.
        #expect(popup.numberOfItems == 3)
        #expect(ProjectWindowController.templatePickerTitles(names) == ["Roofing", "Groundwork", "Roofing (2)"])
        popup.selectItem(at: 2)
        #expect(popup.indexOfSelectedItem == 2)
    }

    @Test("BH-904: importing over a same-named template asks; Keep Both renames, Replace replaces")
    func importConflictIsAChoice() {
        let existing = JobTemplate(name: "Standard")
        var imported = JobTemplate(name: "Standard")
        let kept = ProjectWindowController.mergeImportedTemplate(&imported, into: [existing], choice: .keepBoth)
        #expect(kept.count == 2)
        #expect(kept.map(\.name) == ["Standard", "Standard (2)"])
        var replacing = JobTemplate(name: "Standard")
        let replaced = ProjectWindowController.mergeImportedTemplate(&replacing, into: [existing], choice: .replace)
        #expect(replaced.count == 1 && replaced[0].id == replacing.id)
        var sameID = existing
        let twin = ProjectWindowController.mergeImportedTemplate(&sameID, into: [existing], choice: .keepBoth)
        #expect(Set(twin.map(\.id)).count == 2, "two rows must not share one identity")
    }

    @Test("BH-907: Cancel Tool is enabled while a tool is armed with nothing placed")
    func cancelToolFollowsTheArmedTool() async throws {
        let harness = try await Fix2Harness.make("BH907.pdf", calibrate: false)
        defer { harness.tearDown() }
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZPDFCommandID.cancelTool.rawValue
        #expect(!harness.controller.validateMenuItem(item), "nothing armed → nothing to cancel")
        harness.core.measurement.activate(kind: .length)
        // Old: validation read `placedPoints` only, so an armed empty tool left it disabled.
        #expect(harness.controller.validateMenuItem(item))
        harness.core.measurement.deactivate()
    }

    @Test("BH-910: a verdict from a window-close review that was re-armed since is dropped")
    func staleCloseVerdictIsIgnored() async throws {
        let harness = try await Fix2Harness.make("BH910.pdf", calibrate: false)
        defer { harness.tearDown() }
        let controller = harness.controller
        #expect(controller.windowCloseReviewGeneration == 0)
        #expect(controller.isCurrentWindowCloseReview(nil))
        #expect(!controller.isCurrentWindowCloseReview(UnsafeMutableRawPointer(bitPattern: 1)),
                "a chain that no longer runs must not close or re-ask")
        let text = try source("Window/ProjectWindowController.swift")
        // Old: `contextInfo: nil` and no guard — two chains asked the same document.
        #expect(text.contains("guard isCurrentWindowCloseReview(contextInfo) else { return }"))
    }

    @Test("BH-911: the audit trail is read after the history's queued writes land")
    func auditTrailWaitsForQueuedWrites() throws {
        // The export code moved to its own file in IM-253.
        let text = try source("Window/ProjectWindowController+Export.swift")
        // Old: `core.history.events` read synchronously at the press.
        #expect(text.components(separatedBy: "if includeTrail { await core.history.settle() }").count - 1 == 2)
    }

    @Test("BH-912: two repairs of one file claim two different output names")
    func concurrentRepairsDoNotCollide() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: "/tmp/Damaged.pdf")
        let first = DamagedDrawingRepair.reserveOutput(for: source, in: directory)
        let second = DamagedDrawingRepair.reserveOutput(for: source, in: directory)
        defer {
            DamagedDrawingRepair.releaseOutput(first)
            DamagedDrawingRepair.releaseOutput(second)
        }
        // Old: both saw "(repaired).pdf" free before either wrote it.
        #expect(first != second)
        #expect(first.lastPathComponent == "Damaged (repaired).pdf")
        #expect(second.lastPathComponent == "Damaged (repaired 2).pdf")
    }
}
