import CoreGraphics
import Foundation

/// What a print job does with scale (NL-PDF-06) and with sheets larger than the paper
/// (NL-PDF-07). Pure values: the print view draws what this decides, and the tests assert it
/// without a printer, a panel or a window.
///
/// # The rule this file exists for
///
/// A printed dimension that looks right and measures wrong is the worst thing this application
/// can put on paper. So every page states what scale it is at: the resulting drawing scale when
/// the print factor carries the calibrated ratio onto another exact ratio (a half-size print of a
/// 1:100 sheet *is* a 1:200 print), and "not to scale" when it does not. The old note called
/// every reduction "not to scale", which was wrong for the most common check print there is.
///
/// And a sheet never shrinks silently: "Actual size", "Half size" and a custom percentage that
/// do not fit the paper tile the sheet across several pages instead.
public struct DocumentPrintLayout: Sendable, Equatable {

    /// The print scale a person chooses in the print panel.
    public enum ScaleMode: String, Sendable, Hashable, CaseIterable {
        /// 100 %: the sheet at its own size. Tiled when the paper is smaller.
        case actualSize
        /// 50 %: the standard half-size check print. Tiled when even that does not fit.
        case halfSize
        /// Whatever fits the paper, never enlarged. May be at no standard scale.
        case fitToPaper
        /// A percentage the person types.
        case custom
    }

    /// The choices of one print job.
    public struct Options: Sendable, Equatable {
        public var scaleMode: ScaleMode
        /// Used when ``scaleMode`` is ``ScaleMode/custom``; percent, clamped to 1…400.
        public var customPercent: Double
        /// Whether the markups are painted, or the drawing prints clean.
        public var includeMarkups: Bool
        /// The overlap between neighbouring tiles, in points.
        public var tileOverlap: Double
        /// A scale bar in the calibrated units at the printed ratio, on every sheet that prints
        /// at an exact scale (NL-PDF-06), so anyone can check the paper with a rule.
        public var scaleBar: Bool
        /// A header line on every sheet: the takeoff's name, the sheet and the date.
        public var header: Bool
        /// The Quantity Ledger's summary pages after the sheets.
        public var includeSummary: Bool

        /// Fit to paper, markups on, 10 mm overlap: what printing did before there were options,
        /// so a person who never opens the accessory gets the print they always got — plus the
        /// scale bar, which only appears where the paper is at an exact scale.
        public init(
            scaleMode: ScaleMode = .fitToPaper,
            customPercent: Double = 100,
            includeMarkups: Bool = true,
            tileOverlap: Double = 10 / 25.4 * 72,
            scaleBar: Bool = true,
            header: Bool = false,
            includeSummary: Bool = false
        ) {
            self.scaleMode = scaleMode
            self.customPercent = customPercent
            self.includeMarkups = includeMarkups
            self.tileOverlap = tileOverlap
            self.scaleBar = scaleBar
            self.header = header
            self.includeSummary = includeSummary
        }
    }

    /// A scale bar: `segments` equal parts totalling ``length`` real units, ``paperLength`` points
    /// long on the paper.
    public struct ScaleBar: Sendable, Equatable {
        /// The bar's real length, in ``unit``.
        public var length: Double
        public var unit: String
        public var segments: Int
        /// Points on the paper.
        public var paperLength: Double
    }

    /// The bar for a sheet printed at 1:`printedRatio`: the largest round length (1, 2 or 5 × a
    /// power of ten) whose paper length is at most `targetMillimetres`, in metres or feet.
    public static func scaleBar(printedRatio: Double, imperial: Bool, targetMillimetres: Double = 50) -> ScaleBar? {
        guard printedRatio.isFinite, printedRatio > 0, targetMillimetres > 0 else { return nil }
        let unitMetres = imperial ? 0.3048 : 1.0
        // Real length (in the unit) that `targetMillimetres` of paper stands for.
        let available = targetMillimetres / 1000 * printedRatio / unitMetres
        guard available.isFinite, available > 0 else { return nil }
        let power = pow(10, floor(log10(available)))
        let length = [5.0, 2.0, 1.0].map { $0 * power }.first { $0 <= available * (1 + 1e-9) } ?? power
        let paperMetres = length * unitMetres / printedRatio
        return ScaleBar(
            length: length,
            unit: imperial ? "ft" : "m",
            segments: 4,
            paperLength: paperMetres / 0.0254 * 72
        )
    }

    /// One sheet as the layout sees it.
    public struct Sheet: Sendable, Equatable {
        /// The sheet's size on paper, points.
        public var size: CGSize
        /// The calibrated drawing scale's denominator — 100 for 1:100 — or `nil` when the page
        /// is not calibrated, or is calibrated anisotropically (no single ratio to state).
        public var drawnRatio: Double?

        public init(size: CGSize, drawnRatio: Double?) {
            self.size = size
            self.drawnRatio = drawnRatio
        }
    }

    /// One printed page: which sheet, at what factor, and which part of it.
    public struct Page: Sendable, Equatable {
        public var sheetIndex: Int
        /// Paper points per sheet point.
        public var factor: Double
        /// The part of the *scaled* sheet this page shows, origin top-left, y down — the
        /// print view's flipped space. The whole scaled sheet for an untiled page.
        public var region: CGRect
        /// Row and column (zero-based) and the grid size, for a tiled sheet.
        public var tile: Tile?
    }

    public struct Tile: Sendable, Equatable {
        public var row: Int
        public var column: Int
        public var rows: Int
        public var columns: Int

        /// "B3": the row as a letter, the column as a number.
        public var cell: String { "\(Self.letters(row))\(column + 1)" }
        /// The grid's last cell, "C4" for three rows of four.
        public var lastCell: String { "\(Self.letters(rows - 1))\(columns)" }

        static func letters(_ index: Int) -> String {
            var value = index
            var out = ""
            repeat {
                out = String(UnicodeScalar(UInt8(65 + value % 26))) + out
                value = value / 26 - 1
            } while value >= 0
            return out
        }
    }

    public let pages: [Page]

    /// How far past the paper a fixed-factor sheet may run before it is tiled instead of clipped.
    ///
    /// A half-size A1 is 297 × 420.5 mm and A3 is 297 × 420: tiling that half-millimetre onto a
    /// second sheet would be absurd, and the standard half-size check print loses the same few
    /// millimetres to the printer's margins anyway. Three percent is under 13 mm on A3.
    public static let clipTolerance = 0.03

    public init(sheets: [Sheet], slot: CGSize, options: Options) {
        var pages: [Page] = []
        for (index, sheet) in sheets.enumerated() {
            let factor = Self.factor(for: sheet, slot: slot, options: options)
            let drawn = CGSize(width: sheet.size.width * factor, height: sheet.size.height * factor)
            let fits = drawn.width <= slot.width * (1 + Self.clipTolerance)
                && drawn.height <= slot.height * (1 + Self.clipTolerance)
            if fits || options.scaleMode == .fitToPaper || slot.width <= 0 || slot.height <= 0 {
                pages.append(Page(
                    sheetIndex: index,
                    factor: factor,
                    region: CGRect(origin: .zero, size: drawn),
                    tile: nil
                ))
                continue
            }
            let overlap = min(max(0, options.tileOverlap), min(slot.width, slot.height) / 4)
            let stepX = slot.width - overlap
            let stepY = slot.height - overlap
            let columns = max(1, Int(((drawn.width - overlap) / stepX).rounded(.up)))
            let rows = max(1, Int(((drawn.height - overlap) / stepY).rounded(.up)))
            for row in 0..<rows {
                for column in 0..<columns {
                    pages.append(Page(
                        sheetIndex: index,
                        factor: factor,
                        region: CGRect(
                            x: Double(column) * stepX,
                            y: Double(row) * stepY,
                            width: slot.width,
                            height: slot.height
                        ),
                        tile: Tile(row: row, column: column, rows: rows, columns: columns)
                    ))
                }
            }
        }
        self.pages = pages
    }

    /// The factor a sheet prints at.
    public static func factor(for sheet: Sheet, slot: CGSize, options: Options) -> Double {
        switch options.scaleMode {
        case .actualSize: return 1
        case .halfSize: return 0.5
        case .custom: return min(4, max(0.01, options.customPercent / 100))
        case .fitToPaper:
            guard sheet.size.width > 0, sheet.size.height > 0, slot.width > 0, slot.height > 0 else { return 1 }
            return min(1, slot.width / sheet.size.width, slot.height / sheet.size.height)
        }
    }

    // MARK: - What the page says about its scale

    /// The scale a sheet prints at, as a denominator, when the factor carries the drawn ratio
    /// onto another exact one: 1:100 at 50 % is 200; at 70.71 % it is 141.42…, which is no
    /// drawing scale, and the answer is `nil`.
    public static func printedRatio(drawn: Double?, factor: Double) -> Double? {
        guard let drawn, drawn.isFinite, drawn > 0, factor.isFinite, factor > 0 else { return nil }
        let printed = drawn / factor
        let nearest = printed.rounded()
        guard nearest >= 1, abs(printed - nearest) <= 1e-6 * printed else { return nil }
        return nearest
    }

    /// The sentence printed in the corner of a sheet, or `nil` when there is nothing to say (an
    /// uncalibrated sheet at its own size).
    public static func scaleNote(drawnRatio: Double?, factor: Double) -> String? {
        let percent = Int((factor * 100).rounded())
        let atFullSize = abs(factor - 1) < 1e-9
        if let drawn = drawnRatio, let printed = printedRatio(drawn: drawn, factor: factor) {
            if atFullSize {
                return String(
                    format: NSLocalizedString(
                        "Printed scale 1:%@ (actual size)",
                        comment: "Print note: a calibrated sheet printed at 100 %; the ratio denominator"
                    ),
                    ratioText(printed)
                )
            }
            return String(
                format: NSLocalizedString(
                    "Printed scale 1:%@ (drawn 1:%@ at %d %%)",
                    comment: "Print note: printed ratio, drawn ratio, and the print percentage"
                ),
                ratioText(printed),
                ratioText(drawn),
                percent
            )
        }
        guard !atFullSize else { return nil }
        return String(
            format: NSLocalizedString(
                "Printed at %d %% — not to scale",
                comment: "Print note: a sheet printed at a factor that is no drawing scale; the percentage"
            ),
            percent
        )
    }

    /// `100`, `1250`, or `12.5` — a denominator as a person writes it.
    static func ratioText(_ value: Double) -> String {
        let nearest = value.rounded()
        if abs(value - nearest) < 1e-6 { return String(Int(nearest)) }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// The nominal ratio denominator of a uniform scale on a page: metres per page unit over the
    /// metres a page unit is on paper. Rounded to an integer when within 0.01 of one — a drawing
    /// scale is a nominal ratio and 1:99.9999 is calibration noise.
    public static func drawnRatio(metresPerPoint: Double, userUnit: Double) -> Double? {
        let unit = userUnit.isFinite && userUnit > 0 ? userUnit : 1
        let paperMetres = unit * 0.0254 / 72
        guard metresPerPoint.isFinite, metresPerPoint > 0 else { return nil }
        let ratio = metresPerPoint / paperMetres
        let nearest = ratio.rounded()
        return abs(ratio - nearest) <= 0.01 ? nearest : ratio
    }
}
