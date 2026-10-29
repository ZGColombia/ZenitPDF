import Foundation
import Testing
import ZPDFTestingSupport

/// Checks that every manifest agrees with itself: the stated area is the area of the
/// stated coordinates, the stated length is the length of the stated coordinates, and
/// every coordinate survives the round trip into the file and back.
struct ManifestConsistencyTests {

    /// Tolerance for values that are exact integers in closed form. Anything looser
    /// would let a genuine arithmetic mistake through.
    static let exactTolerance = 1e-12

    @Test("Every fixture kind produces a manifest", arguments: FixtureKind.allCases)
    func manifestExists(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        #expect(manifest.kind == kind)
        #expect(manifest.fileName == kind.fileName)
        #expect(!manifest.title.isEmpty)
        #expect(!manifest.purpose.isEmpty)
        #expect(manifest.pageCount >= 1)
        #expect(manifest.pages.count == manifest.pageCount)
        #expect(manifest.isStructurallyValid == kind.isStructurallyValid)
        for (index, page) in manifest.pages.enumerated() {
            #expect(page.index == index)
            #expect(page.mediaBox.width > 0)
            #expect(page.mediaBox.height > 0)
            #expect([0, 90, 180, 270].contains(page.rotation))
        }
    }

    @Test("Manifests are pure functions of the kind", arguments: FixtureKind.allCases)
    func manifestIsDeterministic(kind: FixtureKind) throws {
        let first = try ZPDFFixtures.manifest(for: kind)
        let second = try ZPDFFixtures.manifest(for: kind)
        #expect(first == second)
    }

    @Test("Stated area equals an independent shoelace over the stated coordinates",
          arguments: FixtureKind.allCases)
    func areaMatchesShoelace(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        for path in manifest.paths {
            switch path.kind {
            case .openPolyline:
                #expect(path.area == 0, "open path \(path.id) must have zero area")
            case .closedPolygon, .polygonWithHoles:
                var signed = IndependentGeometry.shoelaceArea(path.points)
                for hole in path.holes {
                    signed += IndependentGeometry.shoelaceArea(hole)
                }
                let error = IndependentGeometry.relativeError(
                    signed, path.area, floor: path.derivation.magnitudeFloor
                )
                #expect(
                    error <= Self.exactTolerance,
                    "\(kind.rawValue)/\(path.id): shoelace \(signed) vs manifest \(path.area), rel \(error)"
                )
            case .cubicBezierLoop:
                // Handled by `bezierCircleIsInternallyConsistent`.
                break
            }
        }
    }

    @Test("Stated length equals an independent traversal of the stated coordinates",
          arguments: FixtureKind.allCases)
    func lengthMatchesTraversal(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        for path in manifest.paths {
            switch path.kind {
            case .openPolyline:
                let measured = IndependentGeometry.polylineLength(path.points)
                let error = IndependentGeometry.relativeError(
                    measured, path.length, floor: path.derivation.magnitudeFloor
                )
                #expect(
                    error <= Self.exactTolerance,
                    "\(kind.rawValue)/\(path.id): polyline \(measured) vs manifest \(path.length)"
                )
            case .closedPolygon, .polygonWithHoles:
                var measured = IndependentGeometry.ringPerimeter(path.points)
                for hole in path.holes {
                    measured += IndependentGeometry.ringPerimeter(hole)
                }
                let error = IndependentGeometry.relativeError(
                    measured, path.length, floor: path.derivation.magnitudeFloor
                )
                #expect(
                    error <= Self.exactTolerance,
                    "\(kind.rawValue)/\(path.id): perimeter \(measured) vs manifest \(path.length)"
                )
            case .cubicBezierLoop:
                break
            }
        }
    }

    @Test("Recorded condition numbers match the shoelace definition",
          arguments: FixtureKind.allCases)
    func conditionNumbersAreCorrect(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        for path in manifest.paths {
            guard let recorded = path.derivation.conditionNumber else { continue }
            guard path.kind == .closedPolygon || path.kind == .polygonWithHoles else { continue }
            let measured = IndependentGeometry.shoelaceConditionNumber([path.points] + path.holes)
            let error = IndependentGeometry.relativeError(measured, recorded, floor: 1)
            #expect(
                error <= 1e-9,
                "\(kind.rawValue)/\(path.id): kappa \(measured) vs recorded \(recorded)"
            )
        }
    }

    @Test("Every coordinate round-trips through PDF number syntax",
          arguments: FixtureKind.allCases)
    func coordinatesRoundTrip(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        func check(_ value: Double, _ label: String) {
            #expect(
                PDFNumber.roundTrips(value),
                "\(kind.rawValue): \(label) = \(value) does not round-trip as \"\(PDFNumber.string(value))\""
            )
        }
        for page in manifest.pages {
            for box in [page.mediaBox, page.cropBox] {
                check(box.llx, "box.llx")
                check(box.lly, "box.lly")
                check(box.urx, "box.urx")
                check(box.ury, "box.ury")
            }
        }
        for path in manifest.paths {
            for point in path.points + path.holes.flatMap({ $0 }) {
                check(point.x, "\(path.id).x")
                check(point.y, "\(path.id).y")
            }
            for cubic in path.cubics {
                for point in [cubic.p0, cubic.p1, cubic.p2, cubic.p3] {
                    check(point.x, "\(path.id).cubic.x")
                    check(point.y, "\(path.id).cubic.y")
                }
            }
            // BH-694/BH-695: form matrices and form-space geometry are written with the
            // same formatter, so they are held to the same round-trip promise.
            for point in path.sourcePoints ?? [] {
                check(point.x, "\(path.id).source.x")
                check(point.y, "\(path.id).source.y")
            }
            if let matrix = path.transform {
                for (label, value) in [("a", matrix.a), ("b", matrix.b), ("c", matrix.c),
                                       ("d", matrix.d), ("e", matrix.e), ("f", matrix.f)] {
                    check(value, "\(path.id).transform.\(label)")
                }
            }
        }
        for page in manifest.pages {
            if let clip = page.clipPath {
                for (label, value) in [("llx", clip.llx), ("lly", clip.lly), ("urx", clip.urx), ("ury", clip.ury)] {
                    check(value, "page\(page.index).clip.\(label)")
                }
            }
        }
        for text in manifest.texts {
            check(text.origin.x, "\(text.id).origin.x")
            check(text.origin.y, "\(text.id).origin.y")
        }
    }

    @Test("Every derivation is complete and no value came from the code under test",
          arguments: FixtureKind.allCases)
    func derivationsAreComplete(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        for path in manifest.paths {
            #expect(!path.derivation.detail.isEmpty, "\(kind.rawValue)/\(path.id): empty derivation")
            #expect(path.derivation.detail.count >= 24, "\(kind.rawValue)/\(path.id): derivation too thin")
            #expect(path.derivation.magnitudeFloor > 0, "\(kind.rawValue)/\(path.id): floor must be positive")
            #expect(!path.derivation.derivedBy.isEmpty)
            #expect(path.derivation.derivedOn.count == 10)
            #expect(FixtureDerivationMethod.allCases.contains(path.derivation.method))
        }
    }

    @Test("The Bézier circle's control points describe the circle it claims")
    func bezierCircleIsInternallyConsistent() throws {
        let manifest = try ZPDFFixtures.manifest(for: .bezierCircle)
        let path = try #require(manifest.path(id: "circle"))
        #expect(path.kind == .cubicBezierLoop)
        #expect(path.cubics.count == 4)

        let centre = FixturePoint(306, 396)
        let radius = 144.0

        // Every on-curve endpoint lies exactly on the circle.
        for cubic in path.cubics {
            for endpoint in [cubic.p0, cubic.p3] {
                let distance = endpoint.distance(to: centre)
                #expect(abs(distance - radius) <= 1e-12 * radius,
                        "endpoint \(endpoint) is \(distance) from the centre, expected \(radius)")
            }
        }

        // The arcs are chained: each starts where the previous ended, and the loop closes.
        for index in path.cubics.indices {
            let current = path.cubics[index]
            let next = path.cubics[(index + 1) % path.cubics.count]
            #expect(current.p3 == next.p0, "arc \(index) does not meet arc \(index + 1)")
        }

        // Stated length and area are the *true circle's*, not the Bézier's.
        #expect(abs(path.length - 2 * Double.pi * radius) <= 1e-12 * path.length)
        #expect(abs(path.area - Double.pi * radius * radius) <= 1e-12 * path.area)

        // The exact Bézier area from Green's theorem, recomputed here from the closed
        // form, must match a dense flattening of the recorded control points.
        let kappa = 4.0 / 3.0 * (2.0.squareRoot() - 1.0)
        let exactBezierArea = radius * radius * (-0.6 * kappa * kappa + 2.4 * kappa + 2.0)
        let flattened = IndependentGeometry.flattenedArea(path.cubics, samplesPerCurve: 20_000)
        let error = IndependentGeometry.relativeError(flattened, exactBezierArea, floor: 65_144)
        #expect(error <= 1e-8,
                "flattened Bezier area \(flattened) vs closed form \(exactBezierArea), rel \(error)")

        // The documented radial-error bound holds everywhere on the curve, and is tight
        // enough to be worth stating: the observed maximum is at least half the bound.
        let bound = 2.7254e-4
        var observedMax = 0.0
        for cubic in path.cubics {
            for step in 0...4_000 {
                let point = cubic.point(at: Double(step) / 4_000)
                let deviation = abs(point.distance(to: centre) - radius) / radius
                observedMax = max(observedMax, deviation)
            }
        }
        #expect(observedMax <= bound, "radial deviation \(observedMax) exceeds the documented bound \(bound)")
        #expect(observedMax >= bound / 2, "documented bound \(bound) is far looser than the real \(observedMax)")
    }

    @Test("The 10 000-segment fixture states 10 000 segments of length 5")
    func stressFixtureIsExact() throws {
        let manifest = try ZPDFFixtures.manifest(for: .tenThousandSegments)
        #expect(manifest.paths.count == 10_000)
        var total = 0.0
        for path in manifest.paths {
            #expect(path.length == 5)
            total += IndependentGeometry.polylineLength(path.points)
        }
        #expect(total == 50_000)
        #expect(Set(manifest.paths.map(\.id)).count == 10_000)
    }

    @Test("Path identifiers are unique per page", arguments: FixtureKind.allCases)
    func pathIdentifiersAreUnique(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        let identifiers = manifest.paths.map(\.id)
        #expect(Set(identifiers).count == identifiers.count, "\(kind.rawValue) has duplicate path ids")
        let textIdentifiers = manifest.texts.map(\.id)
        #expect(Set(textIdentifiers).count == textIdentifiers.count, "\(kind.rawValue) has duplicate text ids")
    }

    @Test("Manifests survive a JSON round trip", arguments: FixtureKind.allCases)
    func manifestIsCodable(kind: FixtureKind) throws {
        let manifest = try ZPDFFixtures.manifest(for: kind)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(FixtureManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("Clipped-content visibility numbers are stated and smaller than the full path")
    func clippedVisibilityIsStated() throws {
        let manifest = try ZPDFFixtures.manifest(for: .clippedContent)
        let clip = try #require(manifest.pages.first?.clipPath)
        #expect(clip == FixtureRect(llx: 200, lly: 200, urx: 400, ury: 400))

        let line = try #require(manifest.path(id: "crossing-line"))
        #expect(line.length == 400)
        #expect(line.clippedVisibleLength == 200)

        let rect = try #require(manifest.path(id: "overhanging-rect"))
        #expect(rect.area == 90_000)
        #expect(rect.clippedVisibleArea == 40_000)
        #expect(rect.clippedVisibleLength == 0)

        // The stated visible area is the area of the intersection, computed here from
        // the two boxes rather than taken from the manifest.
        let intersection = try #require(
            FixtureRect(x: 150, y: 150, width: 300, height: 300).intersection(clip)
        )
        #expect(intersection.area == rect.clippedVisibleArea)
    }

    @Test("Nested form transforms compose in PDF order")
    func nestedFormTransformsCompose() throws {
        let manifest = try ZPDFFixtures.manifest(for: .nestedFormXObjects)
        #expect(manifest.formNestingDepth == 2)

        let outer = try #require(manifest.path(id: "outer-form-rect"))
        let inner = try #require(manifest.path(id: "inner-form-rect"))

        let outerTransform = try #require(outer.transform)
        let innerTransform = try #require(inner.transform)
        #expect(outerTransform == FixtureMatrix(a: 1.5, b: 0, c: 0, d: 1.5, e: 60, f: 40))
        #expect(innerTransform == FixtureMatrix(a: 3, b: 0, c: 0, d: 3, e: 75, f: 47.5))

        // Page-space points really are the source points under the recorded transform.
        for (source, expected) in zip(try #require(outer.sourcePoints), outer.points) {
            #expect(outerTransform.apply(to: source) == expected)
        }
        for (source, expected) in zip(try #require(inner.sourcePoints), inner.points) {
            #expect(innerTransform.apply(to: source) == expected)
        }

        // A uniform scale multiplies area by its square, which is how the manifest states it.
        #expect(outerTransform.uniformLengthScale == 1.5)
        #expect(innerTransform.uniformLengthScale == 3)
        #expect(outer.area == 100 * 50 * outerTransform.areaScale)
        #expect(inner.area == 30 * 20 * innerTransform.areaScale)
    }

    @Test("Only the background path is flagged as background")
    func backgroundFlagging() throws {
        let manifest = try ZPDFFixtures.manifest(for: .giantBackgroundRectangle)
        let background = manifest.paths.filter(\.isBackground)
        #expect(background.count == 1)
        let full = try #require(background.first)
        #expect(full.id == "background")
        let mediaArea: Double = 612 * 792
        #expect(full.area == mediaArea)
        // The background is at least 50 times larger than anything else on the page.
        let others = manifest.paths.filter { !$0.isBackground }
        #expect(others.count == 2)
        for path in others {
            #expect(path.area * 50 < mediaArea || path.area == 0)
        }
    }
}
