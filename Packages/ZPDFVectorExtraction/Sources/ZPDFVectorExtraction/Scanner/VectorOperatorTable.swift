import CoreGraphics
import Foundation

// MARK: - Callback plumbing

/// Recovers the scan state from the scanner's `info` pointer and charges the operator
/// against the budget.
///
/// `CGPDFOperatorCallback` is `@convention(c)`, so a callback captures nothing: every
/// operator is registered with its own non-capturing closure literal, and all shared
/// behaviour lives in free functions like this one.
@inline(__always)
private func withScanState(
    _ info: UnsafeMutableRawPointer?,
    _ body: (VectorScanState) -> Void
) {
    guard let info else { return }
    let state = Unmanaged<VectorScanState>.fromOpaque(info).takeUnretainedValue()
    // `noteOperator` returns false once a budget has fired or the task was cancelled.
    // `CGPDFScannerScan` has no interruption point, so the remainder of the stream is
    // walked and ignored rather than processed: bounded work, no allocation.
    guard state.noteOperator() else { return }
    body(state)
}

@inline(__always)
private func popNumber(_ scanner: CGPDFScannerRef) -> Double? {
    var value: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &value), value.isFinite else { return nil }
    return Double(value)
}

@inline(__always)
private func popPoint(_ scanner: CGPDFScannerRef) -> CGPoint? {
    guard let y = popNumber(scanner), let x = popNumber(scanner) else { return nil }
    return CGPoint(x: x, y: y)
}

@inline(__always)
private func popName(_ scanner: CGPDFScannerRef) -> String? {
    var pointer: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &pointer) else { return nil }
    return PDFObject.name(pointer)
}

/// Pops `count` numbers and returns them in operand order, or `nil` when any is missing
/// or non-finite.
@inline(__always)
private func popNumbers(_ scanner: CGPDFScannerRef, count: Int) -> [Double]? {
    var values = [Double](repeating: 0, count: count)
    var index = count - 1
    while index >= 0 {
        guard let value = popNumber(scanner) else { return nil }
        values[index] = value
        index -= 1
    }
    return values
}

/// Sets the fill or stroke colour space and its initial colour (`cs`, `CS`).
private func setColorSpace(_ scanner: CGPDFScannerRef, state: VectorScanState, stroking: Bool) {
    // Colour never changes geometry, a filter outcome or availability: an unreadable
    // operand makes the colour unknown (`nil`) and is not counted as malformed content.
    let space = popName(scanner).map {
        VectorFormScanner.resolveColorSpace(named: $0, scanner: scanner)
    } ?? .unsupported
    if stroking {
        state.state.strokeColorSpace = space
        state.state.strokeColor = space.initialColor
    } else {
        state.state.fillColorSpace = space
        state.state.fillColor = space.initialColor
    }
}

/// Sets the colour in the current space (`sc`, `scn`, `SC`, `SCN`). In an unsupported
/// space — a pattern name, a separation tint — the colour becomes unknown.
private func setColor(_ scanner: CGPDFScannerRef, state: VectorScanState, stroking: Bool) {
    let space = stroking ? state.state.strokeColorSpace : state.state.fillColorSpace
    let color = space.componentCount
        .flatMap { popNumbers(scanner, count: $0) }
        .flatMap { space.color($0) }
    if stroking { state.state.strokeColor = color } else { state.state.fillColor = color }
}

/// `g`/`G`, `rg`/`RG`, `k`/`K`: select a device space and set the colour in one step.
private func setDeviceColor(
    _ scanner: CGPDFScannerRef,
    state: VectorScanState,
    space: VectorColorSpace,
    stroking: Bool
) {
    let color = space.componentCount
        .flatMap { popNumbers(scanner, count: $0) }
        .flatMap { space.color($0) }
    if stroking {
        state.state.strokeColorSpace = space
        state.state.strokeColor = color
    } else {
        state.state.fillColorSpace = space
        state.state.fillColor = color
    }
}

/// Builds the `CGPDFOperatorTable` the scanner is driven by.
///
/// The whole standard operator set is registered, including operators the extractor
/// ignores, because the operator budget can only count operators it is called for.
/// Tokens that are not PDF operators at all — `zzq` in the malformed-stream fixture —
/// reach no callback, which is why wall clock is the backstop and not operator count.
enum VectorOperatorTable {

    /// Operators registered purely so that they are counted against the budget.
    static let countedOperators: [String] = [
        "BT", "ET", "BX", "EX", "DP", "MP",
        "i", "j", "J", "M", "ri", "d0", "d1",
        "T*", "Tc", "Td", "TD", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz",
        "'", "\""
    ]

    static func make() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }

        // MARK: Path construction

        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            withScanState(info) { state in
                guard let point = popPoint(scanner) else { return state.noteMalformedOperands() }
                state.moveTo(point)
            }
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            withScanState(info) { state in
                guard let point = popPoint(scanner) else { return state.noteMalformedOperands() }
                state.lineTo(point)
            }
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            withScanState(info) { state in
                guard let y3 = popNumber(scanner), let x3 = popNumber(scanner),
                      let y2 = popNumber(scanner), let x2 = popNumber(scanner),
                      let y1 = popNumber(scanner), let x1 = popNumber(scanner)
                else { return state.noteMalformedOperands() }
                state.curveTo(
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x2, y: y2),
                    end: CGPoint(x: x3, y: y3)
                )
            }
        }
        // `v`: the first control point is the current point.
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            withScanState(info) { state in
                guard let y3 = popNumber(scanner), let x3 = popNumber(scanner),
                      let y2 = popNumber(scanner), let x2 = popNumber(scanner)
                else { return state.noteMalformedOperands() }
                state.curveToFromCurrentPoint(
                    control2: CGPoint(x: x2, y: y2),
                    end: CGPoint(x: x3, y: y3)
                )
            }
        }
        // `y`: the second control point is the end point.
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            withScanState(info) { state in
                guard let y3 = popNumber(scanner), let x3 = popNumber(scanner),
                      let y1 = popNumber(scanner), let x1 = popNumber(scanner)
                else { return state.noteMalformedOperands() }
                state.curveTo(
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x3, y: y3),
                    end: CGPoint(x: x3, y: y3)
                )
            }
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            withScanState(info) { $0.closeSubpath() }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            withScanState(info) { state in
                guard let height = popNumber(scanner), let width = popNumber(scanner),
                      let y = popNumber(scanner), let x = popNumber(scanner)
                else { return state.noteMalformedOperands() }
                state.appendRectangle(x: x, y: y, width: width, height: height)
            }
        }

        // MARK: Painting and discard

        CGPDFOperatorTableSetCallback(table, "S") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: false, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "s") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: false, closesPath: true) }
        }
        CGPDFOperatorTableSetCallback(table, "f") { _, info in
            withScanState(info) { $0.paintPath(stroke: false, fill: true, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "F") { _, info in
            withScanState(info) { $0.paintPath(stroke: false, fill: true, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "f*") { _, info in
            withScanState(info) { $0.paintPath(stroke: false, fill: true, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "B") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: true, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "B*") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: true, closesPath: false) }
        }
        CGPDFOperatorTableSetCallback(table, "b") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: true, closesPath: true) }
        }
        CGPDFOperatorTableSetCallback(table, "b*") { _, info in
            withScanState(info) { $0.paintPath(stroke: true, fill: true, closesPath: true) }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            withScanState(info) { $0.paintPath(stroke: false, fill: false, closesPath: false) }
        }

        // MARK: Clipping

        CGPDFOperatorTableSetCallback(table, "W") { _, info in
            withScanState(info) { $0.pendingClip = true }
        }
        CGPDFOperatorTableSetCallback(table, "W*") { _, info in
            withScanState(info) { $0.pendingClip = true }
        }

        // MARK: Graphics state

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            withScanState(info) { $0.saveState() }
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            withScanState(info) { $0.restoreState() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            withScanState(info) { state in
                guard let f = popNumber(scanner), let e = popNumber(scanner),
                      let d = popNumber(scanner), let c = popNumber(scanner),
                      let b = popNumber(scanner), let a = popNumber(scanner)
                else { return state.noteMalformedOperands() }
                state.concatenate(CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f))
            }
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            withScanState(info) { state in
                guard let width = popNumber(scanner), width >= 0 else {
                    return state.noteMalformedOperands()
                }
                state.state.lineWidth = width
            }
        }
        CGPDFOperatorTableSetCallback(table, "d") { scanner, info in
            withScanState(info) { state in
                guard popNumber(scanner) != nil else { return state.noteMalformedOperands() }
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else {
                    return state.noteMalformedOperands()
                }
                state.state.isDashed = CGPDFArrayGetCount(array) > 0
            }
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            withScanState(info) { state in
                guard let name = popName(scanner) else { return state.noteMalformedOperands() }
                VectorFormScanner.applyExtGState(named: name, scanner: scanner, state: state)
            }
        }

        // MARK: Colour (recorded on primitives, never used to filter)

        CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
            withScanState(info) { setColorSpace(scanner, state: $0, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "CS") { scanner, info in
            withScanState(info) { setColorSpace(scanner, state: $0, stroking: true) }
        }
        CGPDFOperatorTableSetCallback(table, "sc") { scanner, info in
            withScanState(info) { setColor(scanner, state: $0, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "scn") { scanner, info in
            withScanState(info) { setColor(scanner, state: $0, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "SC") { scanner, info in
            withScanState(info) { setColor(scanner, state: $0, stroking: true) }
        }
        CGPDFOperatorTableSetCallback(table, "SCN") { scanner, info in
            withScanState(info) { setColor(scanner, state: $0, stroking: true) }
        }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceGray, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceGray, stroking: true) }
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceRGB, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceRGB, stroking: true) }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceCMYK, stroking: false) }
        }
        CGPDFOperatorTableSetCallback(table, "K") { scanner, info in
            withScanState(info) { setDeviceColor(scanner, state: $0, space: .deviceCMYK, stroking: true) }
        }

        // MARK: XObjects and shading

        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            withScanState(info) { state in
                guard let name = popName(scanner) else { return state.noteMalformedOperands() }
                VectorFormScanner.performDo(named: name, scanner: scanner, state: state)
            }
        }
        CGPDFOperatorTableSetCallback(table, "sh") { _, info in
            withScanState(info) { $0.note(.shadingGeometryNotExtracted) }
        }

        // MARK: Text — never a snap source, inspected only to detect Type 3 linework

        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            withScanState(info) { state in
                guard popNumber(scanner) != nil, let name = popName(scanner) else {
                    return state.noteMalformedOperands()
                }
                VectorFormScanner.inspectFont(named: name, scanner: scanner, state: state)
            }
        }

        // MARK: Inline images
        // `BI … ID … EI` is lexed by CoreGraphics; the binary payload is never parsed.

        CGPDFOperatorTableSetCallback(table, "BI") { _, info in withScanState(info) { _ in } }
        CGPDFOperatorTableSetCallback(table, "ID") { _, info in withScanState(info) { _ in } }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            withScanState(info) { state in
                state.noteInlineImage()
                state.appendRasterRegion(isInline: true, resourceName: nil)
            }
        }

        // MARK: Marked content and optional content

        CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in
            withScanState(info) { state in
                VectorFormScanner.beginMarkedContentWithProperties(scanner: scanner, state: state)
            }
        }
        CGPDFOperatorTableSetCallback(table, "BMC") { scanner, info in
            withScanState(info) { state in
                _ = popName(scanner)
                state.beginMarkedContent(hidesContent: false, layerID: nil)
            }
        }
        CGPDFOperatorTableSetCallback(table, "EMC") { _, info in
            withScanState(info) { $0.endMarkedContent() }
        }

        // MARK: Counted-only operators

        for name in countedOperators {
            name.withCString { cName in
                CGPDFOperatorTableSetCallback(table, cName) { _, info in
                    withScanState(info) { _ in }
                }
            }
        }

        return table
    }
}
