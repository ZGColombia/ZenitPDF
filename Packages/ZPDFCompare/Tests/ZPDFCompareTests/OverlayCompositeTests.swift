import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Revision Overlay's composite, as a value: is it the same every time, does hiding a layer
/// and dimming a layer do what the interface says they do, and does a revision over itself
/// show a person "nothing changed" rather than a doubled drawing.
///
/// Everything here runs on rendered pages rather than on 4×4 fixtures. ``OverlayTests`` already
/// pins the arithmetic at pixel granularity; what is unproved without a real sheet is whether
/// the *pipeline* — render, warp, composite — carries those properties end to end.
struct OverlayCompositeTests {

    // MARK: - Support

    private func rgba(_ composite: OverlayComposite, _ index: Int) -> (Int, Int, Int) {
        (
            Int(composite.image.pixels[index * 4]),
            Int(composite.image.pixels[index * 4 + 1]),
            Int(composite.image.pixels[index * 4 + 2])
        )
    }

    /// The pixels a composite has painted anything on at all — the drawing's own shape.
    private func inkMask(_ composite: OverlayComposite, background: (Int, Int, Int)) -> [Bool] {
        (0..<(composite.image.width * composite.image.height)).map { index in
            rgba(composite, index) != background
        }
    }

    // MARK: - 1. Determinism

    @Test("The same inputs composite to the same bytes, every time and through both entry points")
    func compositeIsDeterministic() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let model = RevisionOverlayModel.testStack(labels: ["baseline", "revised"])
        let first = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 1.5
        )
        let second = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 1.5
        )
        #expect(first.image.pixels == second.image.pixels, "two runs of one overlay differ")
        #expect(first.contributingLayerIDs == second.contributingLayerIDs)

        // And the planned entry point produces the identical picture, not merely a similar one:
        // it is the same compositor with the scale chosen for it rather than passed to it.
        let plan = try OverlayCompositePlan.fit(
            pageBox: try await harness.comparator.pageBox(of: harness.baseline),
            requestedScale: 1.5,
            layerCount: 2,
            maximumPixels: 24_000_000
        )
        #expect(plan.isReduced == false, "a fixture sheet at 1.5 px/pt should not need reducing")
        let planned = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            plan: plan
        )
        #expect(planned.composite.image.pixels == first.image.pixels)
    }

    // MARK: - 2. A revision over itself

    @Test("A revision stacked on itself adds no second drawing, and in Difference cancels exactly")
    func selfOverlayShowsTheSheetAndNothingElse() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        // "Indistinguishable from the single page" means exactly this: the composite paints on
        // the same pixels as the single sheet does and on no others. It is deliberately not
        // stated as byte equality, which would be false and would be false for a good reason —
        // a second application of the same tint at a fractional coverage moves an antialiased
        // edge pixel a second step towards the tint. The shape is what a person reads, and the
        // shape is identical: no ghost line anywhere.
        let single = RevisionOverlayModel.testStack(labels: ["only"], blendMode: .multiply)
        let doubled = RevisionOverlayModel(
            layers: [
                OverlayLayer(id: 0, label: "A", color: single.layers[0].color, blendMode: .multiply),
                OverlayLayer(id: 1, label: "A again", color: single.layers[0].color, blendMode: .multiply)
            ]
        )
        let one = try await harness.comparator.overlay(
            references: [harness.baseline],
            alignments: [.identity],
            model: single,
            scale: 2
        )
        let two = try await harness.comparator.overlay(
            references: [harness.baseline, harness.baseline],
            alignments: [.identity, .identity],
            model: doubled,
            scale: 2
        )
        #expect(one.image.width == two.image.width && one.image.height == two.image.height)
        let onePainted = inkMask(one, background: (255, 255, 255))
        let twoPainted = inkMask(two, background: (255, 255, 255))
        let extra = zip(onePainted, twoPainted).filter { !$0.0 && $0.1 }.count
        let missing = zip(onePainted, twoPainted).filter { $0.0 && !$0.1 }.count
        #expect(extra == 0, "\(extra) pixels are inked by the self-overlay and not by the sheet")
        #expect(missing == 0, "\(missing) pixels are inked by the sheet and not by the self-overlay")

        // Difference is the mode that answers "did anything change", and its answer for a sheet
        // against itself has to be *nothing*, exactly, with no residue anywhere on the page.
        let differenced = try await harness.comparator.overlay(
            references: [harness.baseline, harness.baseline],
            alignments: [.identity, .identity],
            model: RevisionOverlayModel(
                layers: [
                    OverlayLayer(id: 0, label: "A", color: .white, blendMode: .difference),
                    OverlayLayer(id: 1, label: "A again", color: .white, blendMode: .difference)
                ],
                background: .black
            ),
            scale: 2
        )
        let residue = (0..<(differenced.image.width * differenced.image.height))
            .filter { rgba(differenced, $0) != (0, 0, 0) }
        #expect(residue.isEmpty, "\(residue.count) pixels survive a sheet differenced with itself")
    }

    // MARK: - 3. Visibility and opacity

    @Test("Hiding a layer removes its ink and its render; halving opacity halves its coverage")
    func visibilityAndOpacityDoWhatTheySay() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        var model = RevisionOverlayModel(
            layers: [
                OverlayLayer(id: 0, label: "baseline", color: .black, blendMode: .normal),
                OverlayLayer(id: 1, label: "revised", color: .black, blendMode: .normal)
            ]
        )
        let both = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 2
        )
        #expect(both.contributingLayerIDs == [0, 1])

        model.layers[1].isVisible = false
        let baselineOnly = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 2
        )
        #expect(baselineOnly.contributingLayerIDs == [0], "a hidden layer still contributed")
        let withRevision = inkMask(both, background: (255, 255, 255))
        let withoutRevision = inkMask(baselineOnly, background: (255, 255, 255))
        // `.addedEdge` puts an edge on the revision that the baseline does not have, so hiding
        // the revision must take ink off the sheet — and must take off exactly that edge's ink.
        let removed = zip(withRevision, withoutRevision).filter { $0.0 && !$0.1 }.count
        let added = zip(withRevision, withoutRevision).filter { !$0.0 && $0.1 }.count
        #expect(removed > 0, "hiding the revision changed nothing on the sheet")
        #expect(added == 0, "hiding a layer somehow added ink")

        // Opacity is coverage, and a black layer on white paper at half opacity lands exactly
        // half way. Asserted on the ink of the baseline layer alone, so there is one number.
        model.layers[1].isVisible = true
        model.layers[1].isVisible = false
        model.layers[0].opacity = 0.5
        let dimmed = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: model,
            scale: 2
        )
        var checked = 0
        for index in 0..<(baselineOnly.image.width * baselineOnly.image.height) {
            let full = rgba(baselineOnly, index)
            guard full.0 == 0 else { continue }          // solid ink at full opacity
            let half = rgba(dimmed, index)
            #expect(half.0 == 128 && half.1 == 128 && half.2 == 128,
                    "solid ink at half opacity read \(half), not mid grey")
            checked += 1
            if checked >= 64 { break }
        }
        #expect(checked > 0, "the fixture drew no solid ink to dim")
    }

    // MARK: - 4. The plan

    @Test("The plan fits the budget, records that it reduced, and is the same on every call")
    func planIsBoundedAndDeterministic() throws {
        // An A1 sheet (the Synthetic Roof Plan's crop box), as geometry.
        let sheet = CGRect(x: 0, y: 0, width: 2383.94, height: 1683.78)
        let atFit = try OverlayCompositePlan.fit(
            pageBox: sheet, requestedScale: 0.5939 * 2, layerCount: 2, maximumPixels: 24_000_000
        )
        #expect(atFit.isReduced == false)
        #expect(atFit.scale == 0.5939 * 2)
        #expect(atFit.pixelCount <= 24_000_000)

        let at400 = try OverlayCompositePlan.fit(
            pageBox: sheet, requestedScale: 4 * 2, layerCount: 2, maximumPixels: 24_000_000
        )
        #expect(at400.isReduced, "the whole A1 at 400 % on a 2x display cannot fit 24 Mpx")
        #expect(at400.pixelCount <= 24_000_000)
        #expect(at400.resolutionFraction > 0.29 && at400.resolutionFraction < 0.32)
        #expect(try OverlayCompositePlan.fit(
            pageBox: sheet, requestedScale: 8, layerCount: 2, maximumPixels: 24_000_000
        ) == at400, "the same request planned differently twice")

        #expect(throws: CompareFault.self) {
            try OverlayCompositePlan.fit(
                pageBox: sheet, requestedScale: 0, layerCount: 2, maximumPixels: 24_000_000
            )
        }
        #expect(throws: CompareFault.self) {
            try OverlayCompositePlan.fit(
                pageBox: .zero, requestedScale: 2, layerCount: 2, maximumPixels: 24_000_000
            )
        }
    }

    // MARK: - 5. A heavy A1, timed

    /// The Synthetic Roof Plan of `ZPDFTestingSupport` — one A1 vector sheet, 16 341 primitives,
    /// its load tuned to a real CAD-exported A1 (`FIXTURES.md`, "Calibration").
    private static func roofPlan() throws -> URL {
        let url = try ZPDFFixtures.shared(.syntheticRoofPlan).url
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        return url
    }

    @Test("Overlay timing on a heavy A1 at fit and at 400 %, printed")
    func roofPlanOverlayTiming() async throws {
        let url = try Self.roofPlan()
        let provider = PDFKitDocumentProvider()
        defer { Task { await provider.closeAll() } }
        let opened = try await provider.open(fileAt: url)
        let comparator = RevisionComparator(
            source: InProcessRevisionDocumentSource(provider: provider)
        )
        let reference = RevisionPageReference(
            document: opened.handle, pageIndex: 0, box: .crop, fileURL: url, label: "Roof plan"
        )
        let box = try await comparator.pageBox(of: reference)
        let model = RevisionOverlayModel.testStack(labels: ["Current", "Revision"])

        print("--- Revision Overlay composite, A1 roof plan, two layers, 1600x1000 pt at backing scale 2 ---")
        print(String(format: "page box %.2f x %.2f pt, budget %d px",
                     Double(box.width), Double(box.height), 24_000_000))
        for (name, zoom) in [("fit (59.39 %)", 0.5939), ("400 %", 4.0)] {
            let plan = try OverlayCompositePlan.fit(
                pageBox: box, requestedScale: zoom * 2, layerCount: 2, maximumPixels: 24_000_000
            )
            let produced = try await comparator.overlay(
                references: [reference, reference],
                alignments: [.identity, .identity],
                model: model,
                plan: plan
            )
            #expect(produced.composite.image.width == plan.pixelWidth)
            #expect(produced.composite.image.height == plan.pixelHeight)

            // The blend pass on its own, over rasters that are already in hand. The number
            // above is what a person waits for the first time; this is what they wait for when
            // they move an opacity slider, which is the interaction the mode is actually used
            // through and the one the coalescing in the app tier is sized against.
            let page = try await comparator.render(
                reference, scale: plan.scale, maximumPixels: plan.pixelCount
            )
            let sources = [
                OverlaySource(layerID: 0, image: page.image),
                OverlaySource(layerID: 1, image: page.image)
            ]
            let started = DispatchTime.now().uptimeNanoseconds
            let blended = try OverlayCompositor.composite(
                model: model, sources: sources, maximumPixels: plan.pixelCount
            )
            let blendMilliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
            #expect(blended.image.width == plan.pixelWidth)

            print(String(
                format: "%@ — asked %.4f px/pt, composited at %.4f px/pt (%d %% of it), "
                    + "%d x %d = %.2f Mpx, peak ~%d MB · render+warp+blend %.1f ms, "
                    + "blend alone %.1f ms (%.1f Mpx/s)",
                name,
                plan.requestedScale,
                plan.scale,
                Int((plan.resolutionFraction * 100).rounded()),
                plan.pixelWidth,
                plan.pixelHeight,
                Double(plan.pixelCount) / 1_000_000,
                plan.estimatedPeakBytes / 1_000_000,
                produced.elapsedSeconds * 1000,
                blendMilliseconds,
                Double(plan.pixelCount) / 1_000_000 / (blendMilliseconds / 1000)
            ))
        }
    }
}
