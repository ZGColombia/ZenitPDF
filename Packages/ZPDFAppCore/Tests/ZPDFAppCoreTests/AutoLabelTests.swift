import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The "Length A" pattern: a new measurement is labelled tool name + letter,
/// per tool per page; user labels always win; a freed letter is never reused.
@MainActor
struct AutoLabelTests {

    private func makePresenter() throws -> (
        AppMeasurementToolPresenter, TakeoffSession, PageID, DocumentID
    ) {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
            )
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let presenter = AppMeasurementToolPresenter(
            session: session, documentID: documentID, pageID: pageID
        )
        return (presenter, session, pageID, documentID)
    }

    private func commit(
        _ presenter: AppMeasurementToolPresenter,
        kind: Shown.Kind,
        points: [PDFPointValue]
    ) -> MarkupRecord? {
        var committed: MarkupRecord?
        presenter.onCommit = { committed = $0 }
        presenter.activate(kind: kind)
        presenter.appendRawPoints(points)
        presenter.commitActiveMeasurement()
        return committed
    }

    private let lengthPoints = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)]
    private let areaPoints = [
        PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0), PDFPointValue(x: 50, y: 50)
    ]

    @Test("Labels run A, B per tool per page, and Area starts its own alphabet")
    func lettersAdvancePerToolPerPage() throws {
        let (presenter, _, _, _) = try makePresenter()
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Length A")
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Length B")
        #expect(commit(presenter, kind: .area, points: areaPoints)?.label == "Area A")
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Length C")
    }

    @Test("A user-typed label always wins and does not consume a letter")
    func userLabelWins() throws {
        let (presenter, _, _, _) = try makePresenter()
        presenter.defaultLabel = "Perimeter Wall"
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Perimeter Wall")
        presenter.defaultLabel = ""
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Length A",
                "the user label must not have consumed a letter")
    }

    @Test("A freed letter is never reused: the allocator only rises, even past Z")
    func freedLettersAreNeverReused() throws {
        let (presenter, _, _, _) = try makePresenter()
        var labels: [String] = []
        for _ in 0..<28 {
            guard let record = commit(presenter, kind: .length, points: lengthPoints) else {
                Issue.record("commit produced no record")
                return
            }
            labels.append(record.label)
        }
        #expect(labels.first == "Length A")
        #expect(labels[25] == "Length Z")
        #expect(labels[26] == "Length AA", "after Z comes AA")
        #expect(labels[27] == "Length AB")
        #expect(Set(labels).count == labels.count, "a letter was reused")
    }

    @Test("Adopting a snapshot seeds the allocator: a reopened project continues, not restarts")
    func adoptionSeedsFromExistingLabels() async throws {
        let (presenter, session, pageID, documentID) = try makePresenter()
        // The document already holds "Length C" — saved by an earlier session — plus a
        // user label that must not disturb the allocator.
        for label in ["Length C", "Södra fasaden"] {
            let record = MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .length,
                subject: "Length",
                label: label,
                geometry: MeasurementGeometry(
                    pageID: pageID,
                    points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 9, y: 0)]
                ),
                createdAt: Date(),
                modifiedAt: Date()
            )
            _ = try await session.apply(.addMarkup(record))
        }
        presenter.adopt(try await session.snapshot())
        #expect(commit(presenter, kind: .length, points: lengthPoints)?.label == "Length D",
                "the allocator must continue past the highest stored letter")
    }
}
