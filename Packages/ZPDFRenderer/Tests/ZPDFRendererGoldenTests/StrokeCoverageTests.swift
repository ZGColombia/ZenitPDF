import Foundation
import Testing
import ZPDFRenderer
import ZPDFRendererScenario

/// What the stroke coverage model is allowed to differ from Core Graphics by, on the scenes
/// built to expose it.
///
/// # Why this suite exists separately from the golden comparison
///
/// `segment_fragment` computes stroke coverage as arithmetic rather than by sampling a signed
/// distance field. That change moves no geometry and submits no different instances, so the
/// culling goldens cannot see it and `ImageComparator`'s default budget — 0.5 % of pixels
/// perceptibly different, 0.025 per-tile coverage, 2 % total ink — is loose enough to hide a
/// real regression in it. `SceneLibrary.strokeAngles`, `dashAngles`, `roundCapsAndCorners` and
/// `translucentOverlap` are the four scenes built around the cases where the model is
/// approximate rather than exact, and the budgets below are the **measured** figures on those
/// scenes with a little headroom, not the comparator's general-purpose ones.
///
/// # The tolerance, and why it is this and not tighter
///
/// A GPU cannot reproduce Core Graphics' exact-area antialiasing byte for byte: the two filter
/// coverage differently and blend in different arithmetic. What can be held to account is
/// *where* the disagreement is allowed to be. It is allowed to be on individual edge pixels — a
/// single pixel at a dash boundary or on a round cap's rim can differ by a third of a level and
/// the picture is right. It is not allowed to be a region, a shift, or a systematic bias, and
/// those are exactly what the three budgets here measure:
///
/// - **Tile coverage** (0.012): mean alpha over a 16x16 tile. A cap drawn at the wrong radius, a
///   dash boundary half a pixel out everywhere, or an ink-creating cap on an empty dash interval
///   all move a tile by more than this. Measured worst across the four scenes: **0.0075**, on
///   `round-caps-and-corners`. The 4x4 signed-distance quadrature this model replaced measured
///   **0.0348** on that same scene — it failed this budget, which is how its phantom cap on an
///   empty dash interval was found.
/// - **Perceptible pixel population** (0.02 %): the fraction of pixels whose 3x3-blurred channel
///   difference exceeds 8 %. Measured worst **0.0000 %** (the quadrature: 0.0083 %).
/// - **Total ink** (0.8 %): the whole-image alpha sum, which catches a bias too small to fail
///   either of the others but present on every edge. Measured worst **0.51 %** on `dash-angles`
///   (the quadrature: 0.59 %).
///
/// Scene by scene, analytic against quadrature, worst tile / perceptible pixels / total ink:
/// `stroke-angles` 0.0042 / 0 % / 0.27 % against 0.0042 / 0 % / 0.26 %; `dash-angles`
/// 0.0068 / 0 % / 0.51 % against 0.0068 / 0 % / 0.59 %; `round-caps-and-corners`
/// 0.0075 / 0 % / 0.20 % against 0.0348 / 0.0083 % / 0.25 %; `translucent-overlap`
/// 0.0010 / 0 % / 0.005 % against 0.0010 / 0 % / 0.006 %. The analytic model is at least as
/// close to Core Graphics as the quadrature on every one of them.
@Suite("Stroke coverage model", .serialized)
struct StrokeCoverageTests {

    /// The four scenes whose whole purpose is to police the coverage model.
    static let scenes = ["stroke-angles", "dash-angles", "round-caps-and-corners", "translucent-overlap"]

    static let tileBudget = 0.012
    static let differingPixelBudget = 0.0002
    static let inkBudget = 0.008

    @Test("The stroke coverage model matches Core Graphics inside its own stated budget")
    func coverageModelBudget() throws {
        var checked = 0
        for name in Self.scenes {
            let scene = try #require(SceneLibrary.golden(named: name), "no scene \(name)")
            let reference = try Goldens.render(scene, backend: .coreGraphics)
            let metal = try Goldens.render(scene, backend: .metal)
            let result = ImageComparator.compare(metal, reference)
            print(String(
                format: "coverage model | %-24s tileΔ %.4f  differing %.4f%%  inkΔ %.4f%%  maxΔ %.3f",
                (name as NSString).utf8String ?? "",
                result.maximumTileCoverageDifference,
                result.differingPixelFraction * 100,
                abs(result.inkRatio - 1) * 100,
                result.maximumChannelDifference
            ))
            #expect(
                result.maximumTileCoverageDifference <= Self.tileBudget,
                "\(name): tile coverage difference \(result.maximumTileCoverageDifference) over \(Self.tileBudget)"
            )
            #expect(
                result.differingPixelFraction <= Self.differingPixelBudget,
                "\(name): \(result.differingPixelFraction * 100)% of pixels differ perceptibly, over \(Self.differingPixelBudget * 100)%"
            )
            #expect(
                abs(result.inkRatio - 1) <= Self.inkBudget,
                "\(name): total ink ratio \(result.inkRatio) outside 1 ± \(Self.inkBudget)"
            )
            checked += 1
        }
        #expect(checked == 4)
    }

    /// The defect `round-caps-and-corners` was built to find, pinned so it cannot come back.
    @Test("A dashed path that ends inside a gap paints no cap at its end")
    func noCapOnAnEmptyDashInterval() throws {
        // A 90 pt run of an 8/5 pt dash at 100 % zoom on a Retina backing store is 180 device
        // pixels of a 26-pixel period: the last inked run ends at 172 and the path ends at 180,
        // eight pixels into a gap. Both backends must leave the last eight pixels bare. The
        // Metal renderer used to paint a round cap there, because the cap's reach was applied to
        // a dash interval that did not intersect the segment at all.
        let scene = try #require(SceneLibrary.golden(named: "round-caps-and-corners"))
        let reference = try Goldens.render(scene, backend: .coreGraphics)
        let metal = try Goldens.render(scene, backend: .metal)
        // The tile the defect lived in: 16x16 at (240, 128) in the 600x600 render, which is the
        // far end of the third dashed round-capped stroke.
        var referenceInk = 0.0
        var metalInk = 0.0
        for y in 128..<144 {
            for x in 240..<256 {
                let offset = (y * reference.width + x) * 4 + 3
                referenceInk += Double(reference.pixels[offset]) / 255
                metalInk += Double(metal.pixels[offset]) / 255
            }
        }
        print(String(format: "empty-dash-interval tile: CG ink %.3f, Metal ink %.3f", referenceInk, metalInk))
        #expect(referenceInk > 0.5, "the fixture is vacuous: Core Graphics paints nothing in this tile")
        #expect(
            abs(metalInk - referenceInk) < 0.6,
            "Metal painted \(metalInk) of ink where Core Graphics painted \(referenceInk)"
        )
    }
}
