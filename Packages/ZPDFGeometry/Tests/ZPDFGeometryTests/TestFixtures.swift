import CoreGraphics
import Foundation
import ZPDFContracts
@testable import ZPDFGeometry

/// Deterministic identifiers. No `UUID()` anywhere in a test, so a failure is reproducible.
enum Fixture {
    static func uuid(_ n: Int) -> UUID {
        let hex = String(format: "%012x", n)
        return UUID(uuidString: "00000000-0000-0000-0000-\(hex)")!
    }

    static let documentID = DocumentID(uuid(1))

    static func pageID(_ n: Int) -> PageID { PageID(uuid(100 + n)) }
    static func scaleID(_ n: Int) -> ScaleID { ScaleID(uuid(200 + n)) }
    static func regionID(_ n: Int) -> ScaleRegionID { ScaleRegionID(uuid(300 + n)) }

    /// US Letter, no crop, no rotation.
    static func letter(
        index: Int = 0,
        label: String? = nil,
        rotation: PageRotation = .degrees0
    ) -> PageDescriptor {
        PageDescriptor(
            id: pageID(index),
            documentID: documentID,
            index: index,
            label: label ?? "\(index + 1)",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792)),
            rotation: rotation
        )
    }

    /// A4 portrait.
    static func a4(index: Int = 0, label: String? = nil) -> PageDescriptor {
        PageDescriptor(
            id: pageID(index),
            documentID: documentID,
            index: index,
            label: label ?? "\(index + 1)",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 595, height: 842))
        )
    }

    /// A page whose crop box differs from the media box and whose origins are negative.
    static func negativeOriginCropped(
        index: Int = 0,
        rotation: PageRotation = .degrees0
    ) -> PageDescriptor {
        PageDescriptor(
            id: pageID(index),
            documentID: documentID,
            index: index,
            label: "A-\(101 + index)",
            boxes: PageBoxes(
                media: PDFRect(x: -200, y: -100, width: 800, height: 600),
                crop: PDFRect(x: -100, y: -50, width: 300, height: 200)
            ),
            rotation: rotation
        )
    }

    static func square(_ size: Double, at origin: PDFPoint = .zero) -> [PDFPoint] {
        [
            PDFPoint(x: origin.x, y: origin.y),
            PDFPoint(x: origin.x + size, y: origin.y),
            PDFPoint(x: origin.x + size, y: origin.y + size),
            PDFPoint(x: origin.x, y: origin.y + size)
        ]
    }

    static func rectRing(x: Double, y: Double, width: Double, height: Double) -> PolygonRing {
        PolygonRing(points: [
            PDFPoint(x: x, y: y),
            PDFPoint(x: x + width, y: y),
            PDFPoint(x: x + width, y: y + height),
            PDFPoint(x: x, y: y + height)
        ])
    }

    /// 1 page point = 0.01 m exactly, so every expected value below is an exact decimal.
    static func uniformScale(_ n: Int = 0, metresPerPoint: Decimal = Decimal(string: "0.01")!) throws -> ScaleTransform {
        try ScaleTransform.uniform(
            id: scaleID(n),
            metresPerPoint: metresPerPoint,
            units: .metric,
            source: .preset,
            label: "test"
        )
    }
}

/// SplitMix64: a deterministic, seedable generator so the R-tree benchmark measures the same
/// workload on every run and every machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
