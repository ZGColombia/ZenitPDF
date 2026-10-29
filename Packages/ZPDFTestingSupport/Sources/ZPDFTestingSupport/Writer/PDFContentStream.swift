import Foundation

/// Builds a PDF content stream out of operators, using `PDFNumber` for every
/// coordinate so that the bytes in the file agree exactly with the manifest.
struct PDFContentStream {
    private var lines: [String] = []

    init() {}

    mutating func raw(_ line: String) {
        lines.append(line)
    }

    mutating func saveState() { lines.append("q") }
    mutating func restoreState() { lines.append("Q") }

    mutating func concat(_ matrix: FixtureMatrix) {
        lines.append("\(PDFNumber.string(matrix)) cm")
    }

    mutating func setLineWidth(_ width: Double) {
        lines.append("\(PDFNumber.string(width)) w")
    }

    /// Sets a DeviceGray stroking colour, `0` black to `1` white.
    mutating func setStrokeGray(_ level: Double) {
        lines.append("\(PDFNumber.string(level)) G")
    }

    /// Sets a DeviceGray non-stroking colour.
    mutating func setFillGray(_ level: Double) {
        lines.append("\(PDFNumber.string(level)) g")
    }

    mutating func move(to point: FixturePoint) {
        lines.append("\(PDFNumber.string(point)) m")
    }

    mutating func line(to point: FixturePoint) {
        lines.append("\(PDFNumber.string(point)) l")
    }

    mutating func curve(_ cubic: FixtureCubic) {
        lines.append(
            "\(PDFNumber.string(cubic.p1)) \(PDFNumber.string(cubic.p2)) \(PDFNumber.string(cubic.p3)) c"
        )
    }

    mutating func closeSubpath() { lines.append("h") }

    /// Appends a ring as `m`/`l`.../`h`, or leaves it open when `close` is false.
    mutating func appendRing(_ points: [FixturePoint], close: Bool) {
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() { line(to: point) }
        if close { closeSubpath() }
    }

    mutating func appendRectangle(_ rect: FixtureRect) {
        lines.append(
            "\(PDFNumber.string(rect.llx)) \(PDFNumber.string(rect.lly)) "
                + "\(PDFNumber.string(rect.width)) \(PDFNumber.string(rect.height)) re"
        )
    }

    mutating func stroke() { lines.append("S") }
    mutating func fillNonZero() { lines.append("f") }
    mutating func clipNonZeroAndEndPath() { lines.append("W n") }

    /// Draws a named XObject.
    mutating func drawXObject(named name: String) {
        lines.append("/\(name) Do")
    }

    /// Emits a single show-text run at an absolute baseline origin.
    mutating func showText(
        _ escapedLiteral: String,
        font: String,
        size: Double,
        at origin: FixturePoint
    ) {
        lines.append("BT")
        lines.append("/\(font) \(PDFNumber.string(size)) Tf")
        lines.append("1 0 0 1 \(PDFNumber.string(origin)) Tm")
        lines.append("\(escapedLiteral) Tj")
        lines.append("ET")
    }

    /// The finished stream as Latin-1 bytes.
    func data(kind: FixtureKind) throws -> Data {
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .isoLatin1) else {
            throw FixtureError.encodingFailed(kind: kind, reason: "content stream is not Latin-1")
        }
        return data
    }
}
