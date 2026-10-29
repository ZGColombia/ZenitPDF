import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// LT3-05: an area on an uncalibrated sheet used to be drawable in full and then commit
/// nothing — Return and a click on the first vertex did nothing, and the shape sat in limbo
/// until Escape. The first point is now refused with a named warning and a call to action.
@Suite("A measurement on a sheet with no scale is refused up front (LT3-05)")
@MainActor
struct NLMeasureScaleRequiredTests {

    private func environment() async throws -> (AppCoreEnvironment, PageID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_684, height: 2_384))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        environment.measurement.setPage(page.id)
        return (environment, page.id)
    }

    /// Old output: three vertices placed (`placedPoints.count == 3`), `canCommit == false`,
    /// nothing asked of the host — the shape in limbo.
    @Test("The first point of an area is refused and the host is asked for a scale")
    func areaRefusedAtFirstPoint() async throws {
        let (environment, page) = try await environment()
        let measurement = environment.measurement
        var asked: [PageID] = []
        measurement.onScaleRequired = { asked.append($0) }
        measurement.activate(kind: .area)
        // The canvas asks before every click it would route to the tool.
        for point in [(100.0, 100.0), (300.0, 100.0), (300.0, 300.0)] where !measurement.refusesForMissingScale() {
            measurement.placePoint(PDFPointValue(x: point.0, y: point.1))
        }
        await measurement.settlePlacements()
        #expect(measurement.placedPoints.isEmpty, "a vertex landed on a sheet that cannot measure it")
        #expect(measurement.liveWarnings.contains(.missingScale))
        #expect(asked == [page, page, page])
        #expect(measurement.scaleRequiredRefusals == 3)
        #expect(!measurement.canCommit)
    }

    /// Count needs no scale, and neither does a boundary: both still place.
    @Test("Count and boundaries still place on an uncalibrated sheet")
    func countAndBoundariesStillPlace() async throws {
        let (environment, _) = try await environment()
        let measurement = environment.measurement
        var asked = 0
        measurement.onScaleRequired = { _ in asked += 1 }
        measurement.activate(kind: .count)
        #expect(!measurement.refusesForMissingScale())
        measurement.placePoint(PDFPointValue(x: 100, y: 100))
        await measurement.settlePlacements()
        #expect(measurement.placedPoints.count == 1)
        measurement.cancelActiveMeasurement()

        measurement.beginBoundaryCapture(.scaleRegion)
        #expect(!measurement.refusesForMissingScale())
        measurement.placePoint(PDFPointValue(x: 10, y: 10))
        await measurement.settlePlacements()
        #expect(measurement.placedPoints.count == 1)
        #expect(asked == 0)
    }

    /// After a scale is set, the same tool places normally.
    @Test("Once the sheet has a scale, the area places and commits")
    func placesAfterScale() async throws {
        let (environment, page) = try await environment()
        _ = try await environment.commands.setPresetScale(page: page, ratioDenominator: 100)
        await environment.refresh()
        let measurement = environment.measurement
        measurement.activate(kind: .area)
        #expect(!measurement.refusesForMissingScale())
        for point in [(100.0, 100.0), (300.0, 100.0), (300.0, 300.0)] {
            measurement.placePoint(PDFPointValue(x: point.0, y: point.1))
        }
        await measurement.settlePlacements()
        #expect(measurement.placedPoints.count == 3)
        #expect(measurement.scaleRequiredRefusals == 0)
    }
}
