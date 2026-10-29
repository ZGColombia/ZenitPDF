import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The artwork import conversation, driven end to end against a recording handler.
///
/// The two things asserted here are the two import gaps that used to be answered
/// by documentation rather than by behaviour: a multi-page PDF must not import page 1 silently,
/// and the single-ink limit of imported vector artwork must reach the person **before** they
/// commit. Both are properties of the flow, not of a view, which is why the flow is a model.
@MainActor
@Suite(.workflowsTierSerialised)
struct ArtworkImportCoordinatorTests {

    /// A handler that records what it was asked and answers what the test tells it to.
    @MainActor
    final class Recorder {
        var choices: [ArtworkImportChoice] = []
        var inspection = ArtworkSourceSummary(fileName: "seal.pdf", pageCount: 1)
        var importOutcome: ArtworkImportOutcome = .imported(
            StampArtworkDescriptor(kind: .vector, digest: "abc", sourceName: "seal.pdf")
        )
        var inspectionRefusal: String?

        func handler() -> ArtworkImportHandler {
            { [self] choice in
                choices.append(choice)
                if case .inspectPDF = choice {
                    if let inspectionRefusal { return .refused(inspectionRefusal) }
                    return .inspected(inspection)
                }
                return importOutcome
            }
        }
    }

    private func coordinator(_ recorder: Recorder) -> (ArtworkImportCoordinator, Box) {
        let box = Box()
        let coordinator = ArtworkImportCoordinator()
        coordinator.importArtwork = recorder.handler()
        coordinator.onImported = { box.adopted.append($0) }
        return (coordinator, box)
    }

    @MainActor
    final class Box { var adopted: [StampArtworkDescriptor] = [] }

    private let url = URL(fileURLWithPath: "/tmp/seal.pdf")

    @Test("Choosing a PDF inspects it and imports nothing")
    func choosingAPDFInspectsFirst() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "titleblocks.pdf", pageCount: 4)
        let (coordinator, box) = coordinator(recorder)

        await coordinator.choosePDF(at: url)

        #expect(recorder.choices == [.inspectPDF(url: url)])
        #expect(box.adopted.isEmpty, "nothing may be imported before the person presses Import")
        #expect(coordinator.pendingPDF?.summary.pageCount == 4)
        #expect(coordinator.pendingPDF?.offersPageChoice == true)
        #expect(coordinator.pageNumber == 1)
    }

    @Test("A multi-page PDF imports the page the person chose, not page one")
    func importsTheChosenPage() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "titleblocks.pdf", pageCount: 4)
        let (coordinator, box) = coordinator(recorder)

        await coordinator.choosePDF(at: url)
        // A person reads "3 of 4" and means the third page; the importer counts from zero.
        coordinator.pageNumber = 3
        await coordinator.confirm()

        #expect(recorder.choices == [.inspectPDF(url: url), .pdfPage(url: url, pageIndex: 2)])
        #expect(box.adopted.count == 1)
        #expect(coordinator.pendingPDF == nil, "the sheet closes when the import lands")
    }

    @Test("A page number outside the file is clamped rather than refused by the importer")
    func clampsAnImpossiblePage() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "two.pdf", pageCount: 2)
        let (coordinator, _) = coordinator(recorder)

        await coordinator.choosePDF(at: url)
        coordinator.pageNumber = 99
        await coordinator.confirm()

        #expect(recorder.choices.last == .pdfPage(url: url, pageIndex: 1))
    }

    @Test("A one-page PDF still opens the sheet, because the single-ink limit has to be said")
    func onePageStillAsks() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "seal.pdf", pageCount: 1)
        let (coordinator, box) = coordinator(recorder)

        await coordinator.choosePDF(at: url)

        #expect(coordinator.pendingPDF != nil, "the notice is the reason the sheet exists")
        #expect(coordinator.pendingPDF?.offersPageChoice == false, "one page is not a choice")
        #expect(box.adopted.isEmpty)
    }

    @Test("The colour notice says what will happen and names the alternative")
    func theNoticeSaysWhatWillHappen() {
        let notice = ArtworkVectorLimits.singleInkNotice
        // ADR-0011 §2.4 as ruled 2026-09-23: one colour is kept, and the person can recolour.
        // The notice used to say "without colour", which BH-167 made false.
        #expect(notice.contains("drawn in one colour starts in that colour"))
        #expect(notice.contains("recolours"))
        #expect(!notice.contains("without colour"))
        #expect(notice.localizedCaseInsensitiveContains("image"), "the alternative has to be named")
    }

    @Test("Cancelling the sheet imports nothing")
    func cancellingImportsNothing() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "seal.pdf", pageCount: 3)
        let (coordinator, box) = coordinator(recorder)

        await coordinator.choosePDF(at: url)
        coordinator.cancel()

        #expect(coordinator.pendingPDF == nil)
        #expect(recorder.choices == [.inspectPDF(url: url)])
        #expect(box.adopted.isEmpty)
    }

    @Test("A refused inspection keeps the importer's own sentence and opens no sheet")
    func aRefusedInspectionKeepsItsSentence() async {
        let recorder = Recorder()
        recorder.inspectionRefusal = "This artwork has 41 208 contours; the limit is 20 000."
        let (coordinator, _) = coordinator(recorder)

        await coordinator.choosePDF(at: url)

        #expect(coordinator.pendingPDF == nil)
        #expect(coordinator.refusal == "This artwork has 41 208 contours; the limit is 20 000.")
    }

    @Test("A refused import keeps its sentence and closes the sheet")
    func aRefusedImportKeepsItsSentence() async {
        let recorder = Recorder()
        recorder.inspection = ArtworkSourceSummary(fileName: "seal.pdf", pageCount: 2)
        recorder.importOutcome = .refused("The PDF is encrypted.")
        let (coordinator, box) = coordinator(recorder)

        await coordinator.choosePDF(at: url)
        await coordinator.confirm()

        #expect(coordinator.refusal == "The PDF is encrypted.")
        #expect(coordinator.pendingPDF == nil)
        #expect(box.adopted.isEmpty)
    }

    @Test("An image is imported directly: there is no page to choose")
    func anImageSkipsTheSheet() async {
        let recorder = Recorder()
        recorder.importOutcome = .imported(
            StampArtworkDescriptor(kind: .raster, digest: "def", sourceName: "seal.png")
        )
        let imageURL = URL(fileURLWithPath: "/tmp/seal.png")
        let (coordinator, box) = coordinator(recorder)

        await coordinator.chooseImage(at: imageURL)

        #expect(recorder.choices == [.image(url: imageURL)])
        #expect(coordinator.pendingPDF == nil)
        #expect(box.adopted.first?.kind == .raster)
    }

    @Test("Nothing runs without a host handler")
    func inertWithoutAHandler() async {
        let coordinator = ArtworkImportCoordinator()
        #expect(coordinator.isAvailable == false)
        await coordinator.choosePDF(at: url)
        await coordinator.chooseImage(at: url)
        await coordinator.confirm()
        #expect(coordinator.pendingPDF == nil)
        #expect(coordinator.refusal == nil)
    }
}
