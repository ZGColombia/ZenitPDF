import CoreGraphics
import Foundation

/// What counts as a difference, and what counts as noise.
///
/// Two renders of the *same* page at the same scale are bit-identical, so a naive
/// threshold of zero works on the self-comparison and on nothing else. The moment the
/// revision has been warped by an alignment — or came off a different plotter, or was
/// scanned — every edge in the drawing picks up antialiasing differences of a few gray
/// levels and the paper picks up texture. `intensityTolerance` is the amount of that a
/// pixel is allowed before it counts.
public struct RasterDiffTolerance: Sendable, Hashable, Codable {
    /// Gray levels, `0…255`. A pixel whose two values differ by no more than this is
    /// unchanged. The default of 24 absorbs resampling ringing on a stroked edge and
    /// scanner paper texture, and is far below the ~200-level swing of ink appearing on
    /// white paper.
    public var intensityTolerance: Int
    /// A difference above `intensityTolerance × strongDifferenceMultiplier` is "strong",
    /// and only strong pixels raise a region's confidence.
    public var strongDifferenceMultiplier: Double
    /// A connected group with fewer differing pixels than this is dropped. At 150 dpi a
    /// 0.35 mm plotter pen covers about 4 px²; 12 is three of those.
    public var minimumRegionPixelCount: Int
    /// Differing pixels within this many pixels of each other are one region. Without
    /// it, the two sides of a moved line and the dashes of a dashed line come back as
    /// dozens of separate findings.
    public var groupingRadiusPixels: Int
    /// 8-connectivity joins diagonal neighbours, which is what a drawn diagonal line
    /// actually is. 4-connectivity would split it into a staircase of regions.
    public var usesEightConnectivity: Bool
    /// Pixels this close to the bitmap edge are ignored. A warped revision has a
    /// resampling seam at the border, and it is never a design change.
    public var borderMarginPixels: Int

    public init(
        intensityTolerance: Int = 24,
        strongDifferenceMultiplier: Double = 2.0,
        minimumRegionPixelCount: Int = 12,
        groupingRadiusPixels: Int = 3,
        usesEightConnectivity: Bool = true,
        borderMarginPixels: Int = 0
    ) {
        self.intensityTolerance = max(0, min(255, intensityTolerance))
        // Clamped above too: `.infinity` ("never strong") made `Int(24 * inf)` trap inside
        // diff (BH-474). 256 already exceeds any possible 8-bit difference.
        self.strongDifferenceMultiplier = strongDifferenceMultiplier.isNaN
            ? 1 : min(256, max(1, strongDifferenceMultiplier))
        self.minimumRegionPixelCount = max(1, minimumRegionPixelCount)
        self.groupingRadiusPixels = max(0, min(64, groupingRadiusPixels))
        self.usesEightConnectivity = usesEightConnectivity
        self.borderMarginPixels = max(0, borderMarginPixels)
    }

    private enum CodingKeys: String, CodingKey {
        case intensityTolerance, strongDifferenceMultiplier, minimumRegionPixelCount
        case groupingRadiusPixels, usesEightConnectivity, borderMarginPixels
    }

    /// Decoding goes through the clamping initialiser. The synthesised decoder accepted a
    /// negative margin, which made the classification loop index its unsafe buffers at -1
    /// (BH-475).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            intensityTolerance: try container.decode(Int.self, forKey: .intensityTolerance),
            strongDifferenceMultiplier: try container.decode(Double.self, forKey: .strongDifferenceMultiplier),
            minimumRegionPixelCount: try container.decode(Int.self, forKey: .minimumRegionPixelCount),
            groupingRadiusPixels: try container.decode(Int.self, forKey: .groupingRadiusPixels),
            usesEightConnectivity: try container.decode(Bool.self, forKey: .usesEightConnectivity),
            borderMarginPixels: try container.decode(Int.self, forKey: .borderMarginPixels)
        )
    }

    /// The everyday setting: two revisions of the same drawing, rendered by us.
    public static let standard = RasterDiffTolerance()

    /// For pages known to be rendered identically — the self-comparison, and two
    /// revisions that share a plotter. Catches a one-level difference.
    public static let strict = RasterDiffTolerance(
        intensityTolerance: 0,
        minimumRegionPixelCount: 1,
        groupingRadiusPixels: 1
    )

    /// For scanned sheets, where paper texture and JPEG blocking are both present.
    public static let scanned = RasterDiffTolerance(
        intensityTolerance: 48,
        minimumRegionPixelCount: 24,
        groupingRadiusPixels: 5,
        borderMarginPixels: 2
    )
}

public struct RasterDiffOptions: Sendable, Hashable, Codable {
    public var tolerance: RasterDiffTolerance
    /// Above this the result is truncated rather than grown without bound. A page with
    /// more than a few thousand separate difference regions is not reviewable anyway,
    /// and the caller is told the list was cut.
    public var maximumRegions: Int
    /// Refused before allocation.
    public var maximumPixels: Int

    public init(
        tolerance: RasterDiffTolerance = .standard,
        maximumRegions: Int = 5_000,
        maximumPixels: Int = 64_000_000
    ) {
        self.tolerance = tolerance
        self.maximumRegions = max(1, maximumRegions)
        self.maximumPixels = max(1, maximumPixels)
    }

    public static let standard = RasterDiffOptions()
}

/// Counts for the whole page, so a caller can say "0.4 % of the sheet differs" without
/// summing the regions itself.
public struct RasterDiffStatistics: Sendable, Hashable, Codable {
    public let comparedPixelCount: Int
    public let differingPixelCount: Int
    /// Pixels where the revision is darker: ink appeared.
    public let addedPixelCount: Int
    /// Pixels where the revision is lighter: ink disappeared.
    public let removedPixelCount: Int
    /// Groups found before the minimum-size filter.
    public let groupedRegionCount: Int
    /// Groups dropped by the minimum-size filter.
    public let discardedRegionCount: Int

    public init(
        comparedPixelCount: Int,
        differingPixelCount: Int,
        addedPixelCount: Int,
        removedPixelCount: Int,
        groupedRegionCount: Int,
        discardedRegionCount: Int
    ) {
        self.comparedPixelCount = comparedPixelCount
        self.differingPixelCount = differingPixelCount
        self.addedPixelCount = addedPixelCount
        self.removedPixelCount = removedPixelCount
        self.groupedRegionCount = groupedRegionCount
        self.discardedRegionCount = discardedRegionCount
    }

    public var differingFraction: Double {
        comparedPixelCount > 0 ? Double(differingPixelCount) / Double(comparedPixelCount) : 0
    }

    public var isIdentical: Bool { differingPixelCount == 0 }
}

public struct RasterDiffOutcome: Sendable, Hashable, Codable {
    public let regions: [DifferenceRegion]
    public let statistics: RasterDiffStatistics
    /// `true` when ``RasterDiffOptions/maximumRegions`` cut the list short.
    public let wasTruncated: Bool

    public init(regions: [DifferenceRegion], statistics: RasterDiffStatistics, wasTruncated: Bool) {
        self.regions = regions
        self.statistics = statistics
        self.wasTruncated = wasTruncated
    }
}

/// Per-pixel difference, morphological grouping, connected components.
///
/// The pipeline, in order: aligned render → pixel threshold →
/// morphology → connected regions.
///
/// One design decision worth stating: region *bounds* are computed from the pixels that
/// actually differ, never from the dilated grouping mask. Dilation exists to decide
/// which differing pixels belong together; letting it grow the reported rectangle would
/// hand the user a box three pixels too big on every side at every scale.
public enum RasterDiffEngine {

    /// Compares two rasters that already share a frame.
    ///
    /// - Parameters:
    ///   - baseline: the fixed page.
    ///   - revised: the moving page, already resampled into the baseline's frame.
    ///   - frame: the baseline frame, used only to convert pixel bounds to page bounds.
    public static func diff(
        baseline: GrayImage,
        revised: GrayImage,
        frame: RasterFrame,
        options: RasterDiffOptions = .standard
    ) throws -> RasterDiffOutcome {
        try checkCompareCancellation()
        guard baseline.hasSameGeometry(as: revised) else {
            throw CompareFault.mismatchedRasterGeometry(
                baseline: baseline.geometryDescription,
                revised: revised.geometryDescription
            )
        }
        // Component labels and flood-fill indices are 32-bit (R-154), so the budget can never
        // admit more pixels than they address, whatever an option was set to.
        let pixelLimit = min(options.maximumPixels, Self.maximumLabelledPixels)
        guard baseline.pixelCount <= pixelLimit else {
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: baseline.pixelCount, limit: pixelLimit
            )
        }
        guard frame.pixelWidth == baseline.width, frame.pixelHeight == baseline.height else {
            throw CompareFault.mismatchedRasterGeometry(
                baseline: "frame \(frame.pixelWidth)x\(frame.pixelHeight)",
                revised: baseline.geometryDescription
            )
        }

        let width = baseline.width
        let height = baseline.height
        // Re-clamped here as well: the stored properties are `var`, so a value can be
        // mutated past the initialiser after construction (BH-474 / BH-475).
        let tolerance = RasterDiffTolerance(
            intensityTolerance: options.tolerance.intensityTolerance,
            strongDifferenceMultiplier: options.tolerance.strongDifferenceMultiplier,
            minimumRegionPixelCount: options.tolerance.minimumRegionPixelCount,
            groupingRadiusPixels: options.tolerance.groupingRadiusPixels,
            usesEightConnectivity: options.tolerance.usesEightConnectivity,
            borderMarginPixels: options.tolerance.borderMarginPixels
        )
        let strongThreshold = Int(
            (Double(tolerance.intensityTolerance) * tolerance.strongDifferenceMultiplier)
                .rounded(.up)
        )
        let margin = tolerance.borderMarginPixels
        // CR-137: the margin is skipped by the classification loop below, so those pixels
        // were never compared and must not be counted as if they had been. Under the
        // `.scanned` preset the margin is wide enough that `width * height` understated
        // every differing fraction — the number the UI shows as "how much of this sheet
        // changed", and the number a threshold is compared against.
        let comparedPixels = Swift.max(0, width - 2 * margin) * Swift.max(0, height - 2 * margin)

        // Pass 1 — classify every pixel. 0 unchanged, 1 added (revision darker),
        // 2 removed (revision lighter), and the high bit marks a strong difference.
        var mask = [UInt8](repeating: 0, count: width * height)
        var addedPixels = 0
        var removedPixels = 0
        baseline.pixels.withUnsafeBufferPointer { lhs in
            revised.pixels.withUnsafeBufferPointer { rhs in
                mask.withUnsafeMutableBufferPointer { out in
                    for y in margin..<max(margin, height - margin) {
                        let row = y * width
                        for x in margin..<max(margin, width - margin) {
                            let index = row + x
                            let delta = Int(rhs[index]) - Int(lhs[index])
                            let magnitude = abs(delta)
                            guard magnitude > tolerance.intensityTolerance else { continue }
                            var code: UInt8 = delta < 0 ? 1 : 2
                            if delta < 0 { addedPixels += 1 } else { removedPixels += 1 }
                            if magnitude >= strongThreshold { code |= 0x80 }
                            out[index] = code
                        }
                    }
                }
            }
        }

        let differingPixels = addedPixels + removedPixels
        if differingPixels == 0 {
            return RasterDiffOutcome(
                regions: [],
                statistics: RasterDiffStatistics(
                    comparedPixelCount: comparedPixels,
                    differingPixelCount: 0,
                    addedPixelCount: 0,
                    removedPixelCount: 0,
                    groupedRegionCount: 0,
                    discardedRegionCount: 0
                ),
                wasTruncated: false
            )
        }
        try checkCompareCancellation()

        // Pass 2 — morphological dilation, separable, so the cost is O(radius) per pixel
        // per axis rather than O(radius²).
        let grouping = dilate(
            mask: mask,
            width: width,
            height: height,
            radius: tolerance.groupingRadiusPixels
        )
        try checkCompareCancellation()

        // Pass 3 — connected components over the grouping mask, iterative.
        let components = label(
            grouping: grouping,
            width: width,
            height: height,
            eightConnected: tolerance.usesEightConnectivity
        )
        try checkCompareCancellation()

        // Pass 4 — attribute the *undilated* differing pixels to their component.
        var accumulators = [ComponentAccumulator](
            repeating: ComponentAccumulator(), count: components.count
        )
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let code = mask[row + x]
                guard code != 0 else { continue }
                let label = Int(components.labels[row + x])
                guard label > 0 else { continue }
                accumulators[label - 1].add(
                    x: x, y: y, isAdded: (code & 0x7F) == 1, isStrong: (code & 0x80) != 0
                )
            }
        }

        let pixelToPage = try frame.pixelToPage()
        var regions: [DifferenceRegion] = []
        var discarded = 0
        var truncated = false
        // Components are numbered in raster scan order by the labeller, so iterating
        // them in index order is already the stable top-to-bottom, left-to-right order
        // a "next difference" button wants.
        for accumulator in accumulators {
            guard accumulator.count > 0 else { continue }
            guard accumulator.count >= tolerance.minimumRegionPixelCount else {
                discarded += 1
                continue
            }
            if regions.count >= options.maximumRegions {
                truncated = true
                break
            }
            let pixelBounds = CGRect(
                x: Double(accumulator.minX),
                y: Double(accumulator.minY),
                width: Double(accumulator.maxX - accumulator.minX + 1),
                height: Double(accumulator.maxY - accumulator.minY + 1)
            )
            let classification: DifferenceClassification
            if accumulator.removedCount == 0 {
                classification = .added
            } else if accumulator.addedCount == 0 {
                classification = .removed
            } else {
                classification = .changed
            }
            regions.append(
                DifferenceRegion(
                    id: regions.count,
                    signal: .raster,
                    classification: classification,
                    pageBounds: pixelToPage.transformedBounds(of: pixelBounds),
                    pixelBounds: pixelBounds,
                    changedPixelCount: accumulator.count,
                    addedPixelCount: accumulator.addedCount,
                    removedPixelCount: accumulator.removedCount,
                    confidence: RasterDifferenceConfidence.value(
                        strongPixelCount: accumulator.strongCount,
                        changedPixelCount: accumulator.count,
                        minimumRegionPixelCount: tolerance.minimumRegionPixelCount
                    )
                )
            )
        }

        return RasterDiffOutcome(
            regions: regions,
            statistics: RasterDiffStatistics(
                comparedPixelCount: comparedPixels,
                differingPixelCount: differingPixels,
                addedPixelCount: addedPixels,
                removedPixelCount: removedPixels,
                groupedRegionCount: components.count,
                discardedRegionCount: discarded
            ),
            wasTruncated: truncated
        )
    }

    // MARK: - Internals

    private struct ComponentAccumulator {
        var count = 0
        var addedCount = 0
        var removedCount = 0
        var strongCount = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        mutating func add(x: Int, y: Int, isAdded: Bool, isStrong: Bool) {
            count += 1
            if isAdded { addedCount += 1 } else { removedCount += 1 }
            if isStrong { strongCount += 1 }
            minX = Swift.min(minX, x)
            minY = Swift.min(minY, y)
            maxX = Swift.max(maxX, x)
            maxY = Swift.max(maxY, y)
        }
    }

    /// The most pixels one diff labels: labels and flood-fill indices are `Int32`.
    static let maximumLabelledPixels = Int(Int32.max)

    struct ComponentLabelling {
        /// One label per pixel, 4 bytes each (R-154: 8 bytes as `[Int]`, 512 MB at the
        /// 64 M-pixel budget, the largest single allocation of a compare).
        let labels: [Int32]
        /// Number of components; labels run `1...count`, with `0` for background.
        let count: Int
    }

    /// Separable square dilation. `radius == 0` is a copy of the binary mask.
    static func dilate(mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var binary = [UInt8](repeating: 0, count: mask.count)
        for index in 0..<mask.count where mask[index] != 0 { binary[index] = 1 }
        guard radius > 0 else { return binary }

        var horizontal = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            let row = y * width
            // Running count of set pixels in the window, so each pixel is O(1).
            var window = 0
            for x in 0..<min(radius + 1, width) where binary[row + x] != 0 { window += 1 }
            for x in 0..<width {
                horizontal[row + x] = window > 0 ? 1 : 0
                let leaving = x - radius
                let entering = x + radius + 1
                if leaving >= 0, binary[row + leaving] != 0 { window -= 1 }
                if entering < width, binary[row + entering] != 0 { window += 1 }
            }
        }

        var vertical = [UInt8](repeating: 0, count: mask.count)
        for x in 0..<width {
            var window = 0
            for y in 0..<min(radius + 1, height) where horizontal[y * width + x] != 0 { window += 1 }
            for y in 0..<height {
                vertical[y * width + x] = window > 0 ? 1 : 0
                let leaving = y - radius
                let entering = y + radius + 1
                if leaving >= 0, horizontal[leaving * width + x] != 0 { window -= 1 }
                if entering < height, horizontal[entering * width + x] != 0 { window += 1 }
            }
        }
        return vertical
    }

    /// Connected-component labelling with an explicit stack.
    ///
    /// Iterative rather than recursive by requirement, not by taste: a full-page
    /// difference on an A1 sheet at 300 dpi is a single component of some 30 million
    /// pixels, and a recursive flood fill would overflow the stack long before that.
    static func label(
        grouping: [UInt8],
        width: Int,
        height: Int,
        eightConnected: Bool
    ) -> ComponentLabelling {
        var labels = [Int32](repeating: 0, count: grouping.count)
        var next: Int32 = 0
        var stack: [Int32] = []
        stack.reserveCapacity(1024)

        for start in 0..<grouping.count where grouping[start] != 0 && labels[start] == 0 {
            next += 1
            labels[start] = next
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            while let packed = stack.popLast() {
                let index = Int(packed)
                let x = index % width
                let y = index / width
                let xLower = x > 0 ? x - 1 : 0
                let xUpper = x < width - 1 ? x + 1 : width - 1
                let yLower = y > 0 ? y - 1 : 0
                let yUpper = y < height - 1 ? y + 1 : height - 1
                for ny in yLower...yUpper {
                    for nx in xLower...xUpper {
                        if !eightConnected, nx != x, ny != y { continue }
                        let neighbour = ny * width + nx
                        guard grouping[neighbour] != 0, labels[neighbour] == 0 else { continue }
                        labels[neighbour] = next
                        stack.append(Int32(neighbour))
                    }
                }
            }
        }
        return ComponentLabelling(labels: labels, count: Int(next))
    }
}
