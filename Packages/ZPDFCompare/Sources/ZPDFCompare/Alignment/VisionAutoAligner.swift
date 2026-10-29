import CoreGraphics
import Foundation
import Vision

/// Why an automatic alignment attempt did not produce a transform.
///
/// Every one of these is a normal outcome, not an error: a failed auto align falls back
/// to manual.
public enum AutoAlignmentRejection: String, Sendable, Hashable, Codable, CaseIterable {
    /// Vision returned no observation, including when a registration error was caught.
    case noObservation
    /// A raster could not be converted to a CGImage for registration.
    case requestFailed
    /// The returned transform had a non-finite or non-invertible coefficient.
    case transformUnusable
    /// The transform moved the page further than a plausible re-plot offset.
    case translationImplausible
    /// Applying the transform did not measurably reduce the difference between the two
    /// rasters, so there is no evidence it aligned anything.
    case noImprovement
    /// One of the two rasters was too small for registration to mean anything.
    case rasterTooSmall
    /// The two rasters do not share one pixel frame, so registration cannot compare them
    /// (the caller must warp into the fixed frame first).
    case mismatchedGeometry
    /// Cancelled between stages.
    case cancelled
}

/// The evidence behind an accept-or-reject decision.
public struct AutoAlignmentMetrics: Sendable, Hashable, Codable {
    /// Mean absolute gray difference, `0…255`, before applying the candidate transform.
    public let meanAbsoluteDifferenceBefore: Double
    /// The same measure after applying it.
    public let meanAbsoluteDifferenceAfter: Double
    /// The number of candidate interpretations that were measured.
    public let candidatesEvaluated: Int

    public init(
        meanAbsoluteDifferenceBefore: Double,
        meanAbsoluteDifferenceAfter: Double,
        candidatesEvaluated: Int
    ) {
        self.meanAbsoluteDifferenceBefore = meanAbsoluteDifferenceBefore
        self.meanAbsoluteDifferenceAfter = meanAbsoluteDifferenceAfter
        self.candidatesEvaluated = candidatesEvaluated
    }

    /// Fraction of the original difference that the transform removed. Negative when
    /// the transform made things worse.
    public var improvement: Double {
        guard meanAbsoluteDifferenceBefore > 0 else { return 0 }
        return (meanAbsoluteDifferenceBefore - meanAbsoluteDifferenceAfter)
            / meanAbsoluteDifferenceBefore
    }
}

/// The result of an automatic alignment attempt.
public enum AutoAlignmentOutcome: Sendable {
    case accepted(AlignmentSolution, AutoAlignmentMetrics)
    case rejected(AutoAlignmentRejection, AutoAlignmentMetrics?)

    public var solution: AlignmentSolution? {
        if case let .accepted(solution, _) = self { return solution }
        return nil
    }

    public var metrics: AutoAlignmentMetrics? {
        switch self {
        case let .accepted(_, metrics): return metrics
        case let .rejected(_, metrics): return metrics
        }
    }

    public var rejection: AutoAlignmentRejection? {
        if case let .rejected(reason, _) = self { return reason }
        return nil
    }
}

/// Optional automatic alignment through Vision's image registration.
///
/// ### Why Vision and not OpenCV
///
/// The obvious design is an ORB/AKAZE + RANSAC pipeline behind an optional slim OpenCV
/// dependency. OpenCV is not available to this build and is not worth a
/// vendored C++ tree for one optional feature, so the same job is done by
/// `VNTranslationalImageRegistrationRequest` and `VNHomographicImageRegistrationRequest`,
/// which ship with the system. The accept/reject discipline survives the substitution;
/// only the feature detector changed.
///
/// ### Why the result is verified against the pixels
///
/// Vision states the direction and units of its alignment transform in prose, and a
/// mistake in reading that prose is a silent, plausible-looking misalignment — the worst
/// possible failure for a tool whose output is a list of "changes". So this type does
/// not trust the transform. It measures the mean absolute difference between the two
/// rasters before and after applying each candidate interpretation of the observation,
/// and returns the one that measurably improved the match. If none does, the outcome is
/// ``AutoAlignmentRejection/noImprovement`` and the caller falls back to manual
/// alignment. That is cheap — a handful of full-image passes — and it is the only way to
/// be *sure*.
///
/// This type never throws. Every failure path is a value.
public struct VisionAutoAligner: Sendable, Hashable, Codable {
    /// A candidate that would move the sheet by more than this fraction of its own
    /// diagonal is not a re-plot offset; it is a bad match.
    public var maximumTranslationFraction: Double
    /// The candidate must remove at least this fraction of the mean absolute difference
    /// to be accepted.
    public var minimumImprovement: Double
    /// Below this edge length in pixels, registration is not attempted.
    public var minimumEdgePixels: Int
    /// Try the homographic request as well as the translational one. Off by default:
    /// a homography is not an affine map, and forcing one into six parameters is a lie
    /// unless the perspective component is negligible.
    public var attemptsHomography: Bool

    public init(
        maximumTranslationFraction: Double = 0.25,
        minimumImprovement: Double = 0.02,
        minimumEdgePixels: Int = 32,
        attemptsHomography: Bool = false
    ) {
        self.maximumTranslationFraction = max(0, maximumTranslationFraction)
        self.minimumImprovement = max(0, minimumImprovement)
        self.minimumEdgePixels = max(1, minimumEdgePixels)
        self.attemptsHomography = attemptsHomography
    }

    public static let standard = VisionAutoAligner()

    /// Attempts to align `moving` onto `fixed`, both in the same pixel frame.
    ///
    /// - Returns: a solution whose transform is in **pixel space** of that shared frame.
    ///   The caller converts it to page space; see
    ///   ``RasterFrame/pixelToPage()``.
    public func align(moving: GrayImage, fixed: GrayImage) -> AutoAlignmentOutcome {
        guard !Task.isCancelled else { return .rejected(.cancelled, nil) }
        guard moving.hasSameGeometry(as: fixed) else {
            // Named for what it is; it used to be reported as `.rasterTooSmall` (BH-468).
            return .rejected(.mismatchedGeometry, nil)
        }
        guard moving.width >= minimumEdgePixels, moving.height >= minimumEdgePixels else {
            return .rejected(.rasterTooSmall, nil)
        }

        let before: Double
        do {
            before = try moving.meanAbsoluteDifference(to: fixed)
        } catch {
            return .rejected(.mismatchedGeometry, nil)
        }

        guard let movingImage = try? moving.cgImage(), let fixedImage = try? fixed.cgImage() else {
            return .rejected(.requestFailed, nil)
        }

        var observed: [CGAffineTransform] = []
        observed.append(contentsOf: translationalCandidates(moving: movingImage, fixed: fixedImage))
        if attemptsHomography {
            observed.append(contentsOf: homographicCandidates(moving: movingImage, fixed: fixedImage))
        }
        guard !observed.isEmpty else {
            return .rejected(
                .noObservation,
                AutoAlignmentMetrics(
                    meanAbsoluteDifferenceBefore: before,
                    meanAbsoluteDifferenceAfter: before,
                    candidatesEvaluated: 0
                )
            )
        }

        let screened = screenedInterpretations(of: observed, width: moving.width, height: moving.height)
        let candidates = screened.candidates
        guard !candidates.isEmpty else {
            // Named for what happened (R-160): every reading that was otherwise usable moved
            // the sheet further than a re-plot offset. `.transformUnusable` is kept for
            // readings that were all non-finite or non-invertible.
            return .rejected(
                screened.implausibleTranslations > 0 ? .translationImplausible : .transformUnusable,
                AutoAlignmentMetrics(
                    meanAbsoluteDifferenceBefore: before,
                    meanAbsoluteDifferenceAfter: before,
                    candidatesEvaluated: 0
                )
            )
        }

        var best: (transform: AlignmentTransform, difference: Double)?
        var evaluated = 0
        for candidate in candidates {
            if Task.isCancelled { return .rejected(.cancelled, nil) }
            guard let inverse = try? candidate.inverted() else { continue }
            guard let warped = try? moving.resampled(
                using: inverse,
                width: fixed.width,
                height: fixed.height,
                maximumPixels: fixed.pixelCount
            ) else { continue }
            guard let difference = try? warped.meanAbsoluteDifference(to: fixed) else { continue }
            evaluated += 1
            if let current = best {
                if difference < current.difference { best = (candidate, difference) }
            } else {
                best = (candidate, difference)
            }
        }

        guard let winner = best else {
            return .rejected(
                .transformUnusable,
                AutoAlignmentMetrics(
                    meanAbsoluteDifferenceBefore: before,
                    meanAbsoluteDifferenceAfter: before,
                    candidatesEvaluated: evaluated
                )
            )
        }

        let metrics = AutoAlignmentMetrics(
            meanAbsoluteDifferenceBefore: before,
            meanAbsoluteDifferenceAfter: winner.difference,
            candidatesEvaluated: evaluated
        )
        guard metrics.improvement >= minimumImprovement else {
            return .rejected(.noImprovement, metrics)
        }

        let solution = AlignmentSolution(
            transform: winner.transform,
            model: .affine,
            provenance: .automaticVision,
            // CR-131: there are no correspondences here, so there is no page-point
            // residual to report — `.zero` is the honest value, and the gray-level
            // agreement this aligner actually measured goes in the field that is
            // documented in gray levels.
            residual: .zero,
            correspondenceCount: 0,
            conditioning: min(1, max(0, metrics.improvement)),
            pixelDissimilarity: winner.difference
        )
        return .accepted(solution, metrics)
    }

    // MARK: - Vision plumbing

    /// Both requests are performed inside `do`/`catch`. Vision throwing is a normal
    /// outcome here, not an exception to propagate.
    private func translationalCandidates(
        moving: CGImage,
        fixed: CGImage
    ) -> [CGAffineTransform] {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: fixed, options: [:])
        let handler = VNImageRequestHandler(cgImage: moving, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.map(\.alignmentTransform)
    }

    private func homographicCandidates(
        moving: CGImage,
        fixed: CGImage
    ) -> [CGAffineTransform] {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: fixed, options: [:])
        let handler = VNImageRequestHandler(cgImage: moving, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.compactMap { observation -> CGAffineTransform? in
            let matrix = observation.warpTransform
            // Only the affine part is usable. A homography whose perspective row is not
            // negligible is discarded rather than silently flattened.
            // A homography is defined only up to scale: k·H is the same map. Normalise by
            // k = H[2][2] before judging the perspective row instead of discarding every
            // observation whose k is not already 1 (BH-469).
            guard let affine = Self.affinePart(of: matrix) else { return nil }
            return affine
        }
    }

    /// Expands each raw observation into the interpretations that are worth measuring.
    ///
    /// Vision's transform may be expressed in pixels or in normalised image coordinates,
    /// and may map the floating image onto the reference or the reverse, depending on
    /// the request. Rather than encode one reading of the documentation and hope, all
    /// four readings are generated and the pixels decide. Implausible translations are
    /// dropped here so they never cost a resampling pass. Finite, invertible readings
    /// dropped only because their translation exceeded ``maximumTranslationFraction``
    /// are counted so an empty result can say why it is empty (R-160).
    func screenedInterpretations(
        of observations: [CGAffineTransform],
        width: Int,
        height: Int
    ) -> (candidates: [AlignmentTransform], implausibleTranslations: Int) {
        let diagonal = hypot(Double(width), Double(height))
        let limit = diagonal * maximumTranslationFraction
        var results: [AlignmentTransform] = []
        var implausible = 0

        func consider(_ candidate: AlignmentTransform) {
            guard candidate.isFinite, abs(candidate.determinant) > 1e-9 else { return }
            guard hypot(candidate.tx, candidate.ty) <= limit else {
                implausible += 1
                return
            }
            // Deduplicate: four interpretations of a near-zero translation collapse to one.
            for existing in results
            where existing.maximumDeviation(
                from: candidate,
                over: CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
            ) < 1e-6 {
                return
            }
            results.append(candidate)
        }

        for observation in observations {
            let pixelReading = AlignmentTransform(observation)
            // Normalised → pixel is a change of basis, not a rescale of the translation
            // alone: with u = x/w, v = y/h the off-diagonals pick up w/h and h/w (BH-469).
            var normalisedReading = pixelReading
            normalisedReading.tx = pixelReading.tx * Double(width)
            normalisedReading.ty = pixelReading.ty * Double(height)
            normalisedReading.b = pixelReading.b * Double(height) / Double(width)
            normalisedReading.c = pixelReading.c * Double(width) / Double(height)
            // GrayImage is row-0-at-top (y down); Vision's transform may be expressed in the
            // lower-left, y-up frame that `CIImage.transformed(by:)` consumes. Without the
            // y-flipped reading F·T·F (F: y ↦ height − y) a diagonal shift (dx, dy) could
            // never be expressed as (dx, −dy), and was rejected as no improvement (BH-121).
            for reading in [pixelReading, normalisedReading] {
                for candidate in [reading, Self.yFlipped(reading, height: Double(height))] {
                    consider(candidate)
                    if let inverse = try? candidate.inverted() { consider(inverse) }
                }
            }
        }
        return (results, implausible)
    }

    /// The affine part of a homography, normalised by `H[2][2]`, or `nil` when it has a
    /// non-negligible perspective row or a degenerate scale.
    static func affinePart(of matrix: simd_float3x3) -> CGAffineTransform? {
        let k = Double(matrix[2][2])
        guard k.isFinite, abs(k) > 1e-9 else { return nil }
        let perspectiveMagnitude = max(abs(Double(matrix[0][2])), abs(Double(matrix[1][2]))) / abs(k)
        guard perspectiveMagnitude < 1e-6 else { return nil }
        return CGAffineTransform(
            a: CGFloat(Double(matrix[0][0]) / k), b: CGFloat(Double(matrix[0][1]) / k),
            c: CGFloat(Double(matrix[1][0]) / k), d: CGFloat(Double(matrix[1][1]) / k),
            tx: CGFloat(Double(matrix[2][0]) / k), ty: CGFloat(Double(matrix[2][1]) / k)
        )
    }

    /// The same transform read in the other vertical convention: `F ∘ T ∘ F` with
    /// `F(x, y) = (x, height − y)`.
    static func yFlipped(_ t: AlignmentTransform, height: Double) -> AlignmentTransform {
        AlignmentTransform(
            a: t.a, b: -t.b, c: -t.c, d: t.d,
            tx: t.tx + t.c * height,
            ty: height * (1 - t.d) - t.ty
        )
    }
}
