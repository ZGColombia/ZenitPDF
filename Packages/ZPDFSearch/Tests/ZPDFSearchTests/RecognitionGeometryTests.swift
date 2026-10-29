import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge

@testable import ZPDFSearch

@Suite("Recognition geometry")
struct RecognitionGeometryTests {

    /// A crop box with a negative lower-left corner, because that is the case that breaks
    /// every naive implementation.
    static let boxes: [CGRect] = [
        CGRect(x: 0, y: 0, width: 612, height: 792),
        CGRect(x: 0, y: 0, width: 1728, height: 2592),
        CGRect(x: -36, y: -18, width: 648, height: 828),
        CGRect(x: 100, y: 200, width: 400, height: 300)
    ]

    static let rotations = [0, 90, 180, 270]

    @Test("Display space and page space are exact inverses for every rotation")
    func roundTrip() {
        for box in Self.boxes {
            for rotation in Self.rotations {
                for fraction in [0.0, 0.1, 0.5] {
                    let pageRect = CGRect(
                        x: box.minX + box.width * fraction,
                        y: box.minY + box.height * fraction,
                        width: box.width * 0.25,
                        height: box.height * 0.125
                    )
                    let display = PageDisplayGeometry.displayRect(
                        forPageRect: pageRect,
                        box: box,
                        rotation: rotation
                    )
                    let back = RecognitionGeometry.pageRect(
                        forDisplayRect: display,
                        box: box,
                        rotation: rotation
                    )
                    #expect(
                        abs(back.minX - pageRect.minX) < 1e-9,
                        "box \(box) rotation \(rotation): x \(back.minX) != \(pageRect.minX)"
                    )
                    #expect(abs(back.minY - pageRect.minY) < 1e-9)
                    #expect(abs(back.width - pageRect.width) < 1e-9)
                    #expect(abs(back.height - pageRect.height) < 1e-9)
                }
            }
        }
    }

    @Test("A normalised box covering the whole image maps to the whole box")
    func fullPageNormalisedBox() {
        for box in Self.boxes {
            for rotation in Self.rotations {
                let displaySize = PageDisplayGeometry.displaySize(of: box.size, rotation: rotation)
                let mapped = RecognitionGeometry.pageRect(
                    forNormalisedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    displayOrigin: .zero,
                    displaySize: displaySize,
                    box: box,
                    rotation: rotation
                )
                let rect = try? #require(mapped)
                #expect(rect != nil)
                guard let rect else { continue }
                #expect(abs(rect.minX - box.minX) < 1e-9)
                #expect(abs(rect.minY - box.minY) < 1e-9)
                #expect(abs(rect.width - box.width) < 1e-9)
                #expect(abs(rect.height - box.height) < 1e-9)
            }
        }
    }

    @Test("A recognised box in the top-left of an upright page lands in the top-left")
    func orientation() throws {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        // Vision's origin is bottom-left, so "top-left of the image" is y near 1.
        let mapped = try #require(
            RecognitionGeometry.pageRect(
                forNormalisedRect: CGRect(x: 0.05, y: 0.85, width: 0.2, height: 0.05),
                displayOrigin: .zero,
                displaySize: box.size,
                box: box,
                rotation: 0
            )
        )
        #expect(abs(mapped.minX - 30.6) < 1e-6)
        #expect(abs(mapped.minY - 673.2) < 1e-6)
        #expect(abs(mapped.width - 122.4) < 1e-6)
        #expect(abs(mapped.height - 39.6) < 1e-6)
    }

    @Test("Non-finite, degenerate and out-of-unit boxes are rejected or clamped")
    func hostileInput() {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        func map(_ rect: CGRect, size: CGSize = CGSize(width: 612, height: 792)) -> CGRect? {
            RecognitionGeometry.pageRect(
                forNormalisedRect: rect,
                displayOrigin: .zero,
                displaySize: size,
                box: box,
                rotation: 0
            )
        }
        #expect(map(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)) == nil)
        #expect(map(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)) == nil)
        #expect(map(CGRect(x: 0, y: 0, width: 0, height: 0.1)) == nil)
        #expect(map(CGRect(x: 0, y: 0, width: 1, height: 1), size: .zero) == nil)
        // A box slightly outside the unit square is clamped onto the page, not dropped.
        let clamped = try? #require(map(CGRect(x: -0.1, y: -0.1, width: 0.3, height: 0.3)))
        let rect = try? #require(clamped)
        #expect(rect != nil)
        if let rect {
            #expect(abs(rect.minX) < 1e-9)
            #expect(abs(rect.minY) < 1e-9)
            #expect(abs(rect.width - 0.2 * 612) < 1e-9)
            #expect(abs(rect.height - 0.2 * 792) < 1e-9)
        }
    }

    @Test("Rotation is folded into the four right angles, negatives included")
    func rotationNormalisation() {
        #expect(RecognitionGeometry.normalisedRotation(0) == 0)
        #expect(RecognitionGeometry.normalisedRotation(90) == 90)
        #expect(RecognitionGeometry.normalisedRotation(-90) == 270)
        #expect(RecognitionGeometry.normalisedRotation(450) == 90)
        #expect(RecognitionGeometry.normalisedRotation(-450) == 270)
        #expect(RecognitionGeometry.normalisedRotation(360) == 0)
        // A nonsense angle is treated as upright, which is what every reader does.
        #expect(RecognitionGeometry.normalisedRotation(45) == 0)
    }

    @Test("Corners come out counter-clockwise from the lower left")
    func corners() {
        let corners = RecognitionGeometry.corners(of: CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(corners.count == 4)
        #expect(corners[0] == (10, 20))
        #expect(corners[1] == (40, 20))
        #expect(corners[2] == (40, 60))
        #expect(corners[3] == (10, 60))
    }
}
