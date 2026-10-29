import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer

/// The golden scenes, and the stress scenes the benchmarks use.
///
/// Every scene is a pure function of a fixed seed, so `SceneLibrary.goldens` returns the same
/// bytes on every machine and in every process. That is the precondition for storing a PNG and
/// calling it a golden.
public enum SceneLibrary {

    /// Every golden scene, in a stable order.
    public static var goldens: [RenderScene] {
        [
            mixed200(),
            polygonWithHoles(holeCount: 1),
            polygonWithHoles(holeCount: 2),
            polygonWithHoles(holeCount: 3),
            selfTouchingPolygons(),
            dashesAndCaps(zoom: 0.05, name: "dashes-and-caps-zoom-005"),
            dashesAndCaps(zoom: 1.0, name: "dashes-and-caps-zoom-100"),
            dashesAndCaps(zoom: 8.0, name: "dashes-and-caps-zoom-800"),
            rotatedPage(.degrees90),
            rotatedPage(.degrees180),
            rotatedPage(.degrees270),
            textAtThreeSizes(),
            countSymbolGrid(),
            selectionAndSnap(),
            dimensionGrammar(zoom: 1.0, backingScale: 1.0, name: "dimension-grammar"),
            dimensionGrammar(zoom: 0.25, backingScale: 2.0, name: "dimension-grammar-zoom-025"),
            prefixedPills(),
            areaPillConcaveFallback(),
            croppedPageWithOffsetOrigin(),
            retinaHairlines(),
            strokeAngles(),
            dashAngles(),
            roundCapsAndCorners(),
            translucentOverlap(),
            importedVectorArtwork(zoom: 0.25, name: "artwork-vector-zoom-025"),
            importedVectorArtwork(zoom: 1.0, name: "artwork-vector-zoom-100"),
            importedVectorArtwork(zoom: 4.0, name: "artwork-vector-zoom-400"),
            importedRasterArtwork(zoom: 0.25, name: "artwork-raster-zoom-025"),
            importedRasterArtwork(zoom: 1.0, name: "artwork-raster-zoom-100"),
            importedRasterArtwork(zoom: 4.0, name: "artwork-raster-zoom-400"),
            importedCountSymbols()
        ]
    }

    public static func golden(named name: String) -> RenderScene? {
        goldens.first { $0.name == name }
    }

    // MARK: - Scenes

    /// 200 mixed markups: polylines, filled polygons with and without holes, count symbols and
    /// labels, in seven colours, overlapping each other.
    public static func mixed200() -> RenderScene {
        var random = DeterministicRandom(seed: 0x5EED_0001)
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        markups.reserveCapacity(200)

        for index in 0..<200 {
            let color = SceneColors.all[index % SceneColors.all.count]
            let x = random.double(40, 560)
            let y = random.double(40, 750)
            switch index % 5 {
            case 0:
                let count = random.int(2, 6)
                var points: [PDFPoint] = []
                for _ in 0..<count {
                    points.append(PDFPoint(
                        x: x + random.double(-45, 45),
                        y: y + random.double(-45, 45)
                    ))
                }
                markups.append(RenderableMarkup(
                    id: MarkupID(random.uuid()),
                    zIndex: index,
                    shape: .polyline(RenderPolyline(points: points, isClosed: index % 10 == 0)),
                    style: RenderStyle(
                        stroke: color,
                        opacity: 1,
                        lineWidth: random.double(0.4, 3.5),
                        startCap: index % 3 == 0 ? .round : .butt,
                        endCap: index % 3 == 1 ? .square : .butt
                    )
                ))
            case 1:
                let sides = random.int(3, 8)
                let radius = random.double(15, 55)
                var outer: [PDFPoint] = []
                for step in 0..<sides {
                    let angle = 2 * Double.pi * Double(step) / Double(sides)
                    outer.append(PDFPoint(
                        x: x + radius * Foundation.cos(angle),
                        y: y + radius * Foundation.sin(angle)
                    ))
                }
                markups.append(RenderableMarkup(
                    id: MarkupID(random.uuid()),
                    zIndex: index,
                    shape: .filledPolygon(RenderPolygon(outer: outer)),
                    style: RenderStyle(stroke: SceneColors.outline, fill: color, lineWidth: 0.8)
                ))
            case 2:
                let radius = random.double(28, 60)
                var outer: [PDFPoint] = []
                for step in 0..<6 {
                    let angle = 2 * Double.pi * Double(step) / 6
                    outer.append(PDFPoint(
                        x: x + radius * Foundation.cos(angle),
                        y: y + radius * Foundation.sin(angle)
                    ))
                }
                var hole: [PDFPoint] = []
                for step in 0..<5 {
                    let angle = 2 * Double.pi * Double(step) / 5
                    hole.append(PDFPoint(
                        x: x + radius * 0.4 * Foundation.cos(angle),
                        y: y + radius * 0.4 * Foundation.sin(angle)
                    ))
                }
                markups.append(RenderableMarkup(
                    id: MarkupID(random.uuid()),
                    zIndex: index,
                    shape: .filledPolygon(RenderPolygon(outer: outer, holes: [hole])),
                    style: RenderStyle(stroke: SceneColors.outline, fill: color, lineWidth: 1.0)
                ))
            case 3:
                markups.append(RenderableMarkup(
                    id: MarkupID(random.uuid()),
                    zIndex: index,
                    shape: .countSymbol(RenderCountSymbol(
                        center: PDFPoint(x: x, y: y),
                        symbol: CountSymbol.allCases[index % CountSymbol.allCases.count],
                        size: random.double(6, 16)
                    )),
                    style: RenderStyle(stroke: color, lineWidth: 1)
                ))
            default:
                markups.append(RenderableMarkup(
                    id: MarkupID(random.uuid()),
                    zIndex: index,
                    shape: .textLabel(RenderTextLabel(
                        anchorPoint: PDFPoint(x: x, y: y),
                        text: "Q\(index) 12.5 m2",
                        fontName: "Helvetica",
                        fontSize: 8,
                        anchor: .center
                    )),
                    style: RenderStyle(stroke: SceneColors.label)
                ))
            }
        }

        return RenderScene(
            name: "mixed-200",
            purpose: "200 mixed markups of every shape kind, overlapping, at 100 % zoom",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// A rectangle with one, two or three rectangular holes, plus one hole that shares an edge
    /// with the parent — the `QUALITY_BAR` 2.5 "cutout touching parent edge" case, in pixels.
    public static func polygonWithHoles(holeCount: Int) -> RenderScene {
        let page = SceneIdentity.page()
        let outer = [
            PDFPoint(x: 80, y: 120),
            PDFPoint(x: 530, y: 120),
            PDFPoint(x: 530, y: 660),
            PDFPoint(x: 80, y: 660)
        ]
        var holes: [[PDFPoint]] = []
        if holeCount >= 1 {
            holes.append([
                PDFPoint(x: 140, y: 180),
                PDFPoint(x: 280, y: 180),
                PDFPoint(x: 280, y: 320),
                PDFPoint(x: 140, y: 320)
            ])
        }
        if holeCount >= 2 {
            // A triangular hole, so the bridge construction meets a non-axis-aligned contour.
            holes.append([
                PDFPoint(x: 340, y: 200),
                PDFPoint(x: 480, y: 210),
                PDFPoint(x: 400, y: 380)
            ])
        }
        if holeCount >= 3 {
            // Shares the parent's left edge exactly.
            holes.append([
                PDFPoint(x: 80, y: 430),
                PDFPoint(x: 240, y: 430),
                PDFPoint(x: 240, y: 560),
                PDFPoint(x: 80, y: 560)
            ])
        }

        let markup = RenderableMarkup(
            id: MarkupID(UUID(uuidString: "11111111-0000-0000-0000-00000000000\(holeCount)") ?? UUID()),
            zIndex: 0,
            shape: .filledPolygon(RenderPolygon(outer: outer, holes: holes)),
            style: RenderStyle(
                stroke: SceneColors.outline,
                fill: SceneColors.concrete,
                opacity: 1,
                lineWidth: 1.5
            )
        )
        return RenderScene(
            name: "polygon-holes-\(holeCount)",
            purpose: "even-odd fill with \(holeCount) hole(s), one of which shares a parent edge",
            page: page,
            markups: [markup],
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// Two self-touching contours: a pinched figure that revisits a vertex, and a bowtie whose
    /// two lobes meet at a single point. Neither is a simple polygon, and both are the input the
    /// triangulator's desperate mode exists for.
    public static func selfTouchingPolygons() -> RenderScene {
        let page = SceneIdentity.page()
        let pinched = [
            PDFPoint(x: 100, y: 500),
            PDFPoint(x: 280, y: 500),
            PDFPoint(x: 190, y: 620),
            PDFPoint(x: 280, y: 740),
            PDFPoint(x: 100, y: 740),
            PDFPoint(x: 190, y: 620)
        ]
        let bowtie = [
            PDFPoint(x: 340, y: 500),
            PDFPoint(x: 540, y: 740),
            PDFPoint(x: 340, y: 740),
            PDFPoint(x: 540, y: 500)
        ]
        // A square whose hole touches its boundary at exactly one vertex.
        let square = [
            PDFPoint(x: 140, y: 140),
            PDFPoint(x: 460, y: 140),
            PDFPoint(x: 460, y: 420),
            PDFPoint(x: 140, y: 420)
        ]
        let touchingHole = [
            PDFPoint(x: 140, y: 140),
            PDFPoint(x: 280, y: 220),
            PDFPoint(x: 200, y: 340)
        ]

        return RenderScene(
            name: "self-touching",
            purpose: "self-touching and bowtie contours, plus a hole touching the parent at a vertex",
            page: page,
            markups: [
                RenderableMarkup(
                    id: MarkupID(UUID(uuidString: "22222222-0000-0000-0000-000000000001") ?? UUID()),
                    zIndex: 0,
                    shape: .filledPolygon(RenderPolygon(outer: pinched)),
                    style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.steel, lineWidth: 1.2)
                ),
                RenderableMarkup(
                    id: MarkupID(UUID(uuidString: "22222222-0000-0000-0000-000000000002") ?? UUID()),
                    zIndex: 1,
                    shape: .filledPolygon(RenderPolygon(outer: bowtie)),
                    style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.insulation, lineWidth: 1.2)
                ),
                RenderableMarkup(
                    id: MarkupID(UUID(uuidString: "22222222-0000-0000-0000-000000000003") ?? UUID()),
                    zIndex: 2,
                    shape: .filledPolygon(RenderPolygon(outer: square, holes: [touchingHole])),
                    style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 1.2)
                )
            ],
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// Every dash pattern crossed with every cap, at one zoom. Rendered at 5 %, 100 % and 800 %
    /// as three separate scenes, because the dash scaling rule is exactly what changes between
    /// them and a golden at one zoom would not see it.
    public static func dashesAndCaps(zoom: Double, name: String) -> RenderScene {
        let page = SceneIdentity.page()
        // At 800 % the whole page is 124 megapixels, which is neither a realistic viewport nor a
        // sane golden file, so the scene is windowed onto the region the top rows fall in — which
        // is also what the canvas does once the user zooms past fit-to-page.
        let viewport: RenderViewport = zoom >= 4
            ? (RenderViewport.window(
                page,
                zoom: zoom,
                backingScale: 1.0,
                pageRect: PDFRect(x: 60, y: 640, width: 150, height: 100)
              ) ?? RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 1.0))
            : RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: zoom < 0.5 ? 2.0 : 1.0)
        // At 5 % the whole page is 31 x 40 device pixels. Forty-five polylines in that space
        // overlap each other several deep and every one of them is a single pixel wide, which
        // makes a pixel comparison a comparison of rounding, not of rendering. The low-zoom
        // variant therefore uses one straight line per pattern and cap, well separated, on a
        // Retina backing store — still 5 % zoom, still every dash pattern, but a picture in which
        // a real difference would be visible rather than buried.
        let sparse = zoom < 0.5
        let patterns: [(String, RenderDash)] = [
            ("solid", .solid),
            ("dashed", .pattern(runs: [9, 5], phase: 0)),
            ("dotted", .pattern(runs: [1.2, 3.6], phase: 0)),
            ("dash-dot", .pattern(runs: [10, 4, 1.5, 4], phase: 0)),
            ("phase", .pattern(runs: [9, 5], phase: 4))
        ]
        let caps: [RenderCap] = [.butt, .round, .square]
        let widths: [Double] = sparse ? [1.0] : [0.25, 1.0, 4.0]
        let spacing = sparse ? 50.0 : 15.5
        var markups: [RenderableMarkup] = []
        var index = 0
        for (patternIndex, pattern) in patterns.enumerated() {
            for (capIndex, cap) in caps.enumerated() {
                for (widthIndex, width) in widths.enumerated() {
                    let y = 740.0 - Double(index) * spacing
                    markups.append(RenderableMarkup(
                        id: MarkupID(UUID(
                            uuidString: String(
                                format: "33333333-0000-0000-%04d-%012d",
                                patternIndex * 100 + capIndex * 10 + widthIndex,
                                index
                            )
                        ) ?? UUID()),
                        zIndex: index,
                        shape: .polyline(RenderPolyline(points: sparse
                            ? [PDFPoint(x: 60, y: y), PDFPoint(x: 552, y: y)]
                            : [
                                PDFPoint(x: 60, y: y),
                                PDFPoint(x: 300, y: y),
                                PDFPoint(x: 360, y: y - 40),
                                PDFPoint(x: 552, y: y - 40)
                            ]
                        )),
                        style: RenderStyle(
                            stroke: SceneColors.all[index % SceneColors.all.count],
                            lineWidth: width,
                            dash: pattern.1,
                            startCap: cap,
                            endCap: cap
                        )
                    ))
                    index += 1
                }
            }
        }
        return RenderScene(
            name: name,
            purpose: "5 dash patterns x 3 caps x 3 widths at zoom \(zoom)",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }

    /// A geometric ruler drawn on a rotated page, so the crop translation, the quarter turn and
    /// the zoom all have to compose in the right order for the image to match.
    public static func rotatedPage(_ rotation: PageRotation) -> RenderScene {
        let page = SceneIdentity.page(rotation: rotation, cropInset: 18)
        var markups: [RenderableMarkup] = []
        // An L, so the image is not symmetric under any rotation.
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "44444444-0000-0000-0000-000000000001") ?? UUID()),
            zIndex: 0,
            shape: .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 60, y: 60),
                PDFPoint(x: 320, y: 60),
                PDFPoint(x: 320, y: 160),
                PDFPoint(x: 160, y: 160),
                PDFPoint(x: 160, y: 520),
                PDFPoint(x: 60, y: 520)
            ])),
            style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 2)
        ))
        for step in 0..<12 {
            let y = 600.0 + Double(step) * 12
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "44444444-0000-0000-0000-%012d", 100 + step)
                ) ?? UUID()),
                zIndex: 1 + step,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 60, y: y),
                    PDFPoint(x: 60 + Double(step + 1) * 35, y: y)
                ])),
                style: RenderStyle(stroke: SceneColors.ink, lineWidth: 1.5, endCap: .round)
            ))
        }
        // A five-pointed star as a *filled polygon*, not a count symbol: this scene is one the
        // coverage oracle has to be able to judge, and the oracle deliberately does not rasterise
        // atlas ink. The shape is asymmetric under rotation, which is the whole point of it.
        var star: [PDFPoint] = []
        for step in 0..<10 {
            let radius = step % 2 == 0 ? 42.0 : 17.0
            let angle = Double.pi / 2 + Double(step) * Double.pi / 5
            star.append(PDFPoint(
                x: 460 + radius * Foundation.cos(angle),
                y: 400 + radius * Foundation.sin(angle)
            ))
        }
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "44444444-0000-0000-0000-000000000200") ?? UUID()),
            zIndex: 100,
            shape: .filledPolygon(RenderPolygon(outer: star)),
            style: RenderStyle(stroke: SceneColors.count, fill: SceneColors.steel, lineWidth: 1.5)
        ))
        return RenderScene(
            name: "rotated-\(rotation.rawValue)",
            purpose: "page /Rotate \(rotation.rawValue) with an 18 pt crop inset",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// The same string at three sizes, in three anchorings, with a numeric label of the kind a
    /// takeoff actually shows.
    public static func textAtThreeSizes() -> RenderScene {
        let page = SceneIdentity.page()
        let sizes: [Double] = [7, 14, 28]
        var markups: [RenderableMarkup] = []
        for (index, size) in sizes.enumerated() {
            let y = 700.0 - Double(index) * 180
            for (anchorIndex, anchor) in [TextAnchor.topLeading, .center, .bottomTrailing].enumerated() {
                markups.append(RenderableMarkup(
                    id: MarkupID(UUID(
                        uuidString: String(format: "55555555-0000-0000-0000-%012d", index * 10 + anchorIndex)
                    ) ?? UUID()),
                    zIndex: index * 10 + anchorIndex,
                    shape: .textLabel(RenderTextLabel(
                        anchorPoint: PDFPoint(x: 90 + Double(anchorIndex) * 170, y: y),
                        text: "A-101 1 284,75 m2",
                        fontName: "Helvetica",
                        fontSize: size,
                        anchor: anchor
                    )),
                    style: RenderStyle(stroke: SceneColors.label)
                ))
                // A crosshair on the anchor, so a mis-anchored label is visible as a shift
                // relative to a shape that cannot itself be mis-anchored.
                markups.append(RenderableMarkup(
                    id: MarkupID(UUID(
                        uuidString: String(format: "55555555-0000-0000-0000-1%011d", index * 10 + anchorIndex)
                    ) ?? UUID()),
                    zIndex: 500 + index * 10 + anchorIndex,
                    shape: .countSymbol(RenderCountSymbol(
                        center: PDFPoint(x: 90 + Double(anchorIndex) * 170, y: y),
                        symbol: .plus,
                        size: 8
                    )),
                    style: RenderStyle(stroke: SceneColors.count)
                ))
            }
        }
        return RenderScene(
            name: "text-three-sizes",
            purpose: "one string at 7, 14 and 28 pt in three anchorings, with anchor crosshairs",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// Every count symbol at every size the atlas buckets differently.
    public static func countSymbolGrid() -> RenderScene {
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        let sizes: [Double] = [5, 9, 14, 22, 34]
        for (row, size) in sizes.enumerated() {
            for (column, symbol) in CountSymbol.allCases.enumerated() {
                markups.append(RenderableMarkup(
                    id: MarkupID(UUID(
                        uuidString: String(format: "66666666-0000-0000-0000-%012d", row * 100 + column)
                    ) ?? UUID()),
                    zIndex: row * 100 + column,
                    shape: .countSymbol(RenderCountSymbol(
                        center: PDFPoint(x: 70 + Double(column) * 50, y: 660 - Double(row) * 90),
                        symbol: symbol,
                        size: size
                    )),
                    style: RenderStyle(stroke: SceneColors.all[column % SceneColors.all.count])
                ))
            }
        }
        return RenderScene(
            name: "count-symbols",
            purpose: "all 10 count symbols at 5 sizes, spanning several atlas buckets",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// Selection handles, a hover outline and snap feedback with a construction line — the whole
    /// overlay pass, which is the one thing drawn from its own buffers.
    public static func selectionAndSnap() -> RenderScene {
        let page = SceneIdentity.page()
        let primary = MarkupID(UUID(uuidString: "77777777-0000-0000-0000-000000000001") ?? UUID())
        let secondary = MarkupID(UUID(uuidString: "77777777-0000-0000-0000-000000000002") ?? UUID())
        let hovered = MarkupID(UUID(uuidString: "77777777-0000-0000-0000-000000000003") ?? UUID())
        let markups = [
            RenderableMarkup(
                id: primary,
                zIndex: 0,
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: 120, y: 420),
                    PDFPoint(x: 340, y: 420),
                    PDFPoint(x: 340, y: 640),
                    PDFPoint(x: 120, y: 640)
                ])),
                style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 1.5)
            ),
            RenderableMarkup(
                id: secondary,
                zIndex: 1,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 380, y: 430),
                    PDFPoint(x: 540, y: 520),
                    PDFPoint(x: 420, y: 640)
                ])),
                style: RenderStyle(stroke: SceneColors.steel, lineWidth: 3, endCap: .round)
            ),
            RenderableMarkup(
                id: hovered,
                zIndex: 2,
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: 150, y: 150),
                    PDFPoint(x: 460, y: 150),
                    PDFPoint(x: 305, y: 340)
                ])),
                style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.insulation, lineWidth: 1)
            )
        ]
        return RenderScene(
            name: "selection-and-snap",
            purpose: "selection outlines, eight handles, a hover outline and snap feedback",
            page: page,
            markups: markups,
            selection: SelectionSnapshot(
                selectedIDs: [primary, secondary],
                primaryID: primary,
                hoveredID: hovered,
                handleSizeViewPoints: 7
            ),
            snapFeedback: RenderSnapFeedback(
                point: PDFPoint(x: 340, y: 640),
                glyph: .hollowSquare,
                guide: .segment(from: PDFPoint(x: 340, y: 640), to: PDFPoint(x: 540, y: 520)),
                isHeldByHysteresis: false,
                glyphSizeViewPoints: 13
            ),
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// The committed measurement grammar: dimension lines with
    /// arrowheads whose tips are the measured points, extension ticks, the value in a rounded
    /// dark pill on the line, and an area whose label pill sits inside its 18 %-alpha fill.
    ///
    /// Rendered at two zooms because the grammar's whole claim is zoom behaviour: the measured
    /// spans scale with the page while arrowheads, ticks and pills hold their view size.
    public static func dimensionGrammar(zoom: Double, backingScale: Double, name: String) -> RenderScene {
        let page = SceneIdentity.page()
        let ink = RenderStyle(stroke: SceneColors.measurement, lineWidth: 1.4)
        var markups: [RenderableMarkup] = []

        func dimension(_ index: Int, from start: PDFPoint, to end: PDFPoint, label: String) {
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "99999999-0000-0000-0000-%012d", index)
                ) ?? UUID()),
                zIndex: index,
                shape: .dimensionLine(RenderDimensionLine(start: start, end: end, label: label)),
                style: ink
            ))
        }

        // A horizontal dimension across the top, with a label-prefixed value.
        dimension(0, from: PDFPoint(x: 80, y: 700), to: PDFPoint(x: 460, y: 700), label: "Length A: 14,72 m")
        // A vertical one on the right.
        dimension(1, from: PDFPoint(x: 540, y: 90), to: PDFPoint(x: 540, y: 610), label: "3,20 m")
        // A sloped one, so the ticks and arrowheads are exercised off-axis.
        dimension(2, from: PDFPoint(x: 90, y: 110), to: PDFPoint(x: 310, y: 300), label: "2,83 m")
        // A dimension shorter than its own pill: arrows clamp to a third of the span each and
        // the shaft yields to the label without the tips moving.
        dimension(3, from: PDFPoint(x: 100, y: 400), to: PDFPoint(x: 150, y: 400), label: "0,51 m")

        // A committed area: cyan outline, 18 %-alpha fill, and the value pill inside the fill.
        let outer = [
            PDFPoint(x: 200, y: 430), PDFPoint(x: 430, y: 430), PDFPoint(x: 430, y: 610),
            PDFPoint(x: 320, y: 650), PDFPoint(x: 200, y: 610)
        ]
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "99999999-0000-0000-0000-000000000100") ?? UUID()),
            zIndex: 100,
            shape: .filledPolygon(RenderPolygon(outer: outer)),
            style: RenderStyle(
                stroke: SceneColors.measurement,
                fill: SceneColors.measurementFill,
                lineWidth: 1.4
            )
        ))
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "99999999-0000-0000-0000-000000000101") ?? UUID()),
            zIndex: 101,
            shape: .labelPill(RenderLabelPill(
                anchorPoint: PDFPoint(x: 315, y: 525),
                text: "Area C: 21,34 m²"
            )),
            style: ink
        ))

        return RenderScene(
            name: name,
            purpose: "dimension-line grammar (arrowheads, ticks, value pills) at zoom \(zoom)",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: backingScale)
        )
    }

    /// The committed pill grammar with **label prefixes**:
    /// a length pill reading "Length A: 14.72 m" on its dimension line, and an area pill
    /// reading "Area C: 21.34 m²" anchored *inside* the polygon fill at the centroid the
    /// shipping `AreaPillPlacement` computes.
    public static func prefixedPills() -> RenderScene {
        let page = SceneIdentity.page()
        let ink = RenderStyle(stroke: SceneColors.measurement, lineWidth: 1.4)

        var markups: [RenderableMarkup] = []
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000000") ?? UUID()),
            zIndex: 0,
            shape: .dimensionLine(RenderDimensionLine(
                start: PDFPoint(x: 90, y: 720), end: PDFPoint(x: 470, y: 720),
                label: "Length A: 14.72 m"
            )),
            style: ink
        ))

        // A convex area: the centroid placement holds, so the pill sits in the fill.
        let outer = [
            PDFPoint(x: 150, y: 260), PDFPoint(x: 430, y: 260), PDFPoint(x: 470, y: 420),
            PDFPoint(x: 300, y: 560), PDFPoint(x: 130, y: 430)
        ]
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000001") ?? UUID()),
            zIndex: 1,
            shape: .filledPolygon(RenderPolygon(outer: outer)),
            style: RenderStyle(
                stroke: SceneColors.measurement,
                fill: SceneColors.measurementFill,
                lineWidth: 1.4
            )
        ))
        let areaText = "Area C: 21.34 m²"
        let extents = estimatedPillHalfExtents(text: areaText, fontSizeViewPoints: 10)
        let placement = AreaPillPlacement.placement(
            polygon: outer,
            pillHalfWidth: extents.halfWidth,
            pillHalfHeight: extents.halfHeight
        )
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000002") ?? UUID()),
            zIndex: 2,
            shape: .labelPill(RenderLabelPill(
                anchorPoint: placement?.center ?? PDFPoint(x: 300, y: 400),
                text: areaText
            )),
            style: ink
        ))

        return RenderScene(
            name: "pill-prefixed",
            purpose: "label-prefixed value pills: length on its line, area inside its fill",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// The concave fallback: a C-shaped area whose centroid falls in the notch, outside
    /// the fill — so the pill steps out to the polygon's bottom vertex on a short
    /// leader, the same placement a Count caption uses.
    public static func areaPillConcaveFallback() -> RenderScene {
        let page = SceneIdentity.page()
        let ink = RenderStyle(stroke: SceneColors.measurement, lineWidth: 1.4)

        // A "C" opening to the right. Its centroid (~292, 430) is inside the notch.
        let outer = [
            PDFPoint(x: 200, y: 260), PDFPoint(x: 440, y: 260), PDFPoint(x: 440, y: 320),
            PDFPoint(x: 260, y: 320), PDFPoint(x: 260, y: 540), PDFPoint(x: 440, y: 540),
            PDFPoint(x: 440, y: 600), PDFPoint(x: 200, y: 600)
        ]
        var markups: [RenderableMarkup] = []
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000010") ?? UUID()),
            zIndex: 0,
            shape: .filledPolygon(RenderPolygon(outer: outer)),
            style: RenderStyle(
                stroke: SceneColors.measurement,
                fill: SceneColors.measurementFill,
                lineWidth: 1.4
            )
        ))
        let text = "Area D: 4.87 m²"
        let extents = estimatedPillHalfExtents(text: text, fontSizeViewPoints: 10)
        let placement = AreaPillPlacement.placement(
            polygon: outer,
            pillHalfWidth: extents.halfWidth,
            pillHalfHeight: extents.halfHeight
        )
        if let placement, let start = placement.leaderStart, let end = placement.leaderEnd {
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000011") ?? UUID()),
                zIndex: 1,
                shape: .polyline(RenderPolyline(points: [start, end])),
                style: ink
            ))
        }
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "88888888-0000-0000-0000-000000000012") ?? UUID()),
            zIndex: 2,
            shape: .labelPill(RenderLabelPill(
                anchorPoint: placement?.center ?? PDFPoint(x: 200, y: 200),
                text: text
            )),
            style: ink
        ))

        return RenderScene(
            name: "pill-concave-fallback",
            purpose: "area pill edge-anchored on a leader when the centroid leaves a concave fill",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// A deterministic estimate of a pill's half extents for scene construction, in
    /// view points — generous enough for the fit test without laying glyphs out. The
    /// drawn pill uses real metrics; placement only needs the box's order of magnitude.
    static func estimatedPillHalfExtents(
        text: String,
        fontSizeViewPoints: Double
    ) -> (halfWidth: Double, halfHeight: Double) {
        let width = Double(text.count) * fontSizeViewPoints * 0.62
        let height = fontSizeViewPoints * 1.25
        return (
            width / 2 + MarkupCompiler.DimensionGrammar.pillPaddingXViewPoints,
            height / 2 + MarkupCompiler.DimensionGrammar.pillPaddingYViewPoints
        )
    }

    /// A page whose media box does not start at the origin and whose crop box is inset, viewed at
    /// backing scale 1. Retina invariance is checked against this one in the unit suite.
    public static func croppedPageWithOffsetOrigin() -> RenderScene {
        let page = SceneIdentity.page(cropInset: 36, origin: PDFPoint(x: -120, y: 240))
        var markups: [RenderableMarkup] = []
        for step in 0..<8 {
            let offset = Double(step) * 30
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "88888888-0000-0000-0000-%012d", step)
                ) ?? UUID()),
                zIndex: step,
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: -60 + offset, y: 300 + offset),
                    PDFPoint(x: 60 + offset, y: 300 + offset),
                    PDFPoint(x: 60 + offset, y: 420 + offset),
                    PDFPoint(x: -60 + offset, y: 420 + offset)
                ])),
                style: RenderStyle(
                    stroke: SceneColors.outline,
                    fill: SceneColors.all[step % SceneColors.all.count],
                    lineWidth: 1
                )
            ))
        }
        return RenderScene(
            name: "cropped-offset-origin",
            purpose: "media box origin at (-120, 240), 36 pt crop inset, backing scale 1",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }

    /// Hairlines and a fill on a Retina backing store, windowed.
    ///
    /// Backing scale is the one viewport field that changes the *pixel* answer without changing
    /// the view-point answer, so it needs a golden of its own; making it a window keeps the file
    /// small enough that the suite stays runnable in a debug build.
    public static func retinaHairlines() -> RenderScene {
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        for step in 0..<12 {
            let y = 420.0 + Double(step) * 11
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "AAAAAAAA-0000-0000-0000-%012d", step)
                ) ?? UUID()),
                zIndex: step,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 210, y: y),
                    PDFPoint(x: 390, y: y)
                ])),
                style: RenderStyle(
                    stroke: SceneColors.ink,
                    lineWidth: 0.05 * Double(step + 1),
                    dash: step % 3 == 0 ? .pattern(runs: [3, 2], phase: 0) : .solid,
                    startCap: .round,
                    endCap: .square
                )
            ))
        }
        markups.append(RenderableMarkup(
            id: MarkupID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000100") ?? UUID()),
            zIndex: 100,
            shape: .filledPolygon(RenderPolygon(
                outer: [
                    PDFPoint(x: 215, y: 290),
                    PDFPoint(x: 385, y: 290),
                    PDFPoint(x: 385, y: 400),
                    PDFPoint(x: 215, y: 400)
                ],
                holes: [[
                    PDFPoint(x: 250, y: 320),
                    PDFPoint(x: 320, y: 320),
                    PDFPoint(x: 285, y: 375)
                ]]
            )),
            style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 0.75)
        ))
        let viewport = RenderViewport.window(
            page,
            zoom: 1.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 200, y: 280, width: 200, height: 290)
        ) ?? RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        return RenderScene(
            name: "retina-hairlines",
            purpose: "sub-pixel line widths and a holed fill at backing scale 2, windowed",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }

    // MARK: - Stress scenes

    // MARK: - Scenes that police the stroke coverage model
    //
    // `segment_fragment` computes stroke coverage as arithmetic rather than by sampling a signed
    // distance field. The four scenes below exist because the culling goldens cannot see a change
    // of that kind: culling changes what is submitted, and these change what a submitted fragment
    // is worth. Each one is built around a case where the analytic model is approximate rather
    // than exact, so that a change to it moves pixels here first.

    /// Thin strokes at twenty-four orientations, at four widths.
    ///
    /// The coverage model integrates over a unit box aligned to the **segment**, not to the pixel
    /// grid, so its error depends on the angle between the two and is largest near 45 degrees. A
    /// fan at 7.5-degree steps puts every part of that curve in one picture, at widths that
    /// straddle the one-device-pixel floor (0.25 and 0.5 pt are floored, 1.0 and 2.0 pt are not).
    public static func strokeAngles() -> RenderScene {
        let page = SceneIdentity.page()
        let widths: [Double] = [0.25, 0.5, 1.0, 2.0]
        var markups: [RenderableMarkup] = []
        for index in 0..<24 {
            let column = index % 6
            let row = index / 6
            let centre = PDFPoint(x: 194 + Double(column) * 48, y: 424 + Double(row) * 48)
            let angle = Double.pi * Double(index) / 24
            let half = 20.0
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0000-0000-%012d", index)
                ) ?? UUID()),
                zIndex: index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: centre.x - half * Foundation.cos(angle),
                             y: centre.y - half * Foundation.sin(angle)),
                    PDFPoint(x: centre.x + half * Foundation.cos(angle),
                             y: centre.y + half * Foundation.sin(angle))
                ])),
                style: RenderStyle(
                    stroke: SceneColors.all[index % SceneColors.all.count],
                    lineWidth: widths[index % widths.count]
                )
            ))
        }
        let viewport = RenderViewport.window(
            page,
            zoom: 1.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 164, y: 394, width: 300, height: 204)
        ) ?? RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        return RenderScene(
            name: "stroke-angles",
            purpose: "24 orientations x 4 widths, solid, butt caps — the coverage model's angle dependence",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }

    /// Dashes at twenty-four orientations, three patterns and three phases.
    ///
    /// A dash boundary is a corner of ink, and a corner is where a distance-field ramp and an
    /// exact interval coverage differ most. Rotating the pattern also rotates the phase of the
    /// boundaries against the pixel grid, which is the effect that once made a dotted line print
    /// a third too dark.
    public static func dashAngles() -> RenderScene {
        let page = SceneIdentity.page()
        let patterns: [RenderDash] = [
            .pattern(runs: [9, 5], phase: 0),
            .pattern(runs: [1.2, 3.6], phase: 0),
            .pattern(runs: [10, 4, 1.5, 4], phase: 0)
        ]
        let phases: [Double] = [0, 2.5, 5]
        let widths: [Double] = [0.5, 1.0, 3.0]
        var markups: [RenderableMarkup] = []
        for index in 0..<24 {
            let column = index % 6
            let row = index / 6
            let centre = PDFPoint(x: 194 + Double(column) * 48, y: 424 + Double(row) * 48)
            let angle = Double.pi * Double(index) / 24
            let half = 21.0
            let base = patterns[index % patterns.count]
            let dash: RenderDash
            if case let .pattern(runs, _) = base {
                dash = .pattern(runs: runs, phase: phases[(index / 3) % phases.count])
            } else {
                dash = base
            }
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0001-0000-%012d", index)
                ) ?? UUID()),
                zIndex: index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: centre.x - half * Foundation.cos(angle),
                             y: centre.y - half * Foundation.sin(angle)),
                    PDFPoint(x: centre.x + half * Foundation.cos(angle),
                             y: centre.y + half * Foundation.sin(angle))
                ])),
                style: RenderStyle(
                    stroke: SceneColors.all[index % SceneColors.all.count],
                    lineWidth: widths[index % widths.count],
                    dash: dash
                )
            ))
        }
        let viewport = RenderViewport.window(
            page,
            zoom: 1.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 164, y: 394, width: 300, height: 204)
        ) ?? RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        return RenderScene(
            name: "dash-angles",
            purpose: "24 orientations x 3 dash patterns x 3 phases — dash boundaries off the pixel grid",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }

    /// Round caps at eight widths, and polylines whose interior angles close to eighty degrees.
    ///
    /// Round is the one cap whose reach along the centreline varies across the stroke, so it is
    /// the one case the separable coverage product cannot express and the strip integration
    /// exists for. Interior joints of a polyline are round by construction
    /// (`MarkupCompiler`), so a zigzag that closes to a spike is a round cap seen from the inside
    /// of a corner, drawn twice and blended — the most demanding arrangement the renderer makes.
    public static func roundCapsAndCorners() -> RenderScene {
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        for index in 0..<8 {
            let y = 560.0 - Double(index) * 15
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0002-0000-%012d", index)
                ) ?? UUID()),
                zIndex: index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 185, y: y),
                    PDFPoint(x: 185 + 90 * Foundation.cos(Double(index) * 0.11),
                             y: y + 90 * Foundation.sin(Double(index) * 0.11))
                ])),
                style: RenderStyle(
                    stroke: SceneColors.all[index % SceneColors.all.count],
                    lineWidth: 1.0 + Double(index),
                    dash: index < 3 ? .pattern(runs: [8, 5], phase: 0) : .solid,
                    startCap: .round,
                    endCap: .round
                )
            ))
        }
        // Spikes: each polyline folds back on itself at a closing angle, so its single interior
        // joint is a round cap wedged into an acute corner.
        for index in 0..<6 {
            let closing = Double.pi * (0.72 - Double(index) * 0.055)  // 130 down to 81 degrees
            let apex = PDFPoint(x: 200 + Double(index % 3) * 88, y: index < 3 ? 428 : 350)
            let arm = 38.0
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0003-0000-%012d", index)
                ) ?? UUID()),
                zIndex: 100 + index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: apex.x - arm * Foundation.cos(closing / 2),
                             y: apex.y + arm * Foundation.sin(closing / 2)),
                    apex,
                    PDFPoint(x: apex.x + arm * Foundation.cos(closing / 2),
                             y: apex.y + arm * Foundation.sin(closing / 2))
                ])),
                style: RenderStyle(
                    stroke: SceneColors.measurement,
                    lineWidth: 4.0,
                    startCap: .square,
                    endCap: .butt
                )
            ))
        }
        let viewport = RenderViewport.window(
            page,
            zoom: 1.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 150, y: 320, width: 300, height: 300)
        ) ?? RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        return RenderScene(
            name: "round-caps-and-corners",
            purpose: "round caps at 8 widths and 6 acute joints — the one case the coverage product cannot separate",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }

    /// Translucent fills and translucent strokes, stacked several deep.
    ///
    /// A coverage error that is invisible on one opaque edge is multiplied by the number of
    /// layers when translucent ink is composited over translucent ink, and it shows up as a
    /// colour shift in the overlap rather than as a soft edge. Six fills at 30–50 % alpha and
    /// three translucent strokes crossing all of them make that error, if there is one, the most
    /// visible thing in the picture.
    public static func translucentOverlap() -> RenderScene {
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        for index in 0..<6 {
            let angle = 2 * Double.pi * Double(index) / 6
            let centre = PDFPoint(x: 300 + 34 * Foundation.cos(angle),
                                  y: 470 + 34 * Foundation.sin(angle))
            var outer: [PDFPoint] = []
            for step in 0..<5 {
                let vertex = 2 * Double.pi * Double(step) / 5 + angle * 0.3
                outer.append(PDFPoint(x: centre.x + 62 * Foundation.cos(vertex),
                                      y: centre.y + 62 * Foundation.sin(vertex)))
            }
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0004-0000-%012d", index)
                ) ?? UUID()),
                zIndex: index,
                shape: .filledPolygon(RenderPolygon(outer: outer)),
                style: RenderStyle(
                    stroke: SceneColors.outline,
                    fill: SceneColors.all[index % SceneColors.all.count],
                    opacity: 0.45,
                    lineWidth: 1.5
                )
            ))
        }
        for index in 0..<3 {
            let y = 400.0 + Double(index) * 46
            markups.append(RenderableMarkup(
                id: MarkupID(UUID(
                    uuidString: String(format: "5AA5AA55-0000-0005-0000-%012d", index)
                ) ?? UUID()),
                zIndex: 200 + index,
                shape: .polyline(RenderPolyline(points: [
                    PDFPoint(x: 180, y: y),
                    PDFPoint(x: 420, y: y + 30)
                ])),
                style: RenderStyle(
                    stroke: SceneColors.measurement,
                    opacity: 0.4,
                    lineWidth: 3.0 + Double(index) * 2,
                    dash: index == 1 ? .pattern(runs: [9, 9], phase: 0) : .solid,
                    startCap: .round,
                    endCap: .round
                )
            ))
        }
        let viewport = RenderViewport.window(
            page,
            zoom: 1.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 170, y: 370, width: 260, height: 220)
        ) ?? RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        return RenderScene(
            name: "translucent-overlap",
            purpose: "6 translucent fills and 3 translucent strokes stacked — coverage error multiplied by depth",
            page: page,
            markups: markups,
            viewport: viewport
        )
    }


    /// `count` markups spread over the page, in the same proportions a real takeoff has: mostly
    /// polylines and filled areas, a fifth count markers, a tenth labels.
    ///
    /// Deterministic in `count` and `seed`, so the 10 000 and 100 000 runs are reproducible and
    /// the incremental benchmark can rebuild the identical scene with one markup moved.
    public static func stress(count: Int, seed: UInt64 = 0x5EED_BEEF) -> (page: PageDescriptor, markups: [RenderableMarkup]) {
        var random = DeterministicRandom(seed: seed)
        let page = SceneIdentity.page()
        var markups: [RenderableMarkup] = []
        markups.reserveCapacity(count)
        for index in 0..<count {
            let x = random.double(10, 600)
            let y = random.double(10, 780)
            let color = SceneColors.all[index % SceneColors.all.count]
            let id = MarkupID(random.uuid())
            switch index % 10 {
            case 0, 1, 2, 3:
                let vertices = random.int(2, 4)
                var points: [PDFPoint] = [PDFPoint(x: x, y: y)]
                for _ in 0..<vertices {
                    points.append(PDFPoint(
                        x: x + random.double(-8, 8),
                        y: y + random.double(-8, 8)
                    ))
                }
                markups.append(RenderableMarkup(
                    id: id,
                    zIndex: index,
                    shape: .polyline(RenderPolyline(points: points)),
                    style: RenderStyle(
                        stroke: color,
                        lineWidth: random.double(0.3, 2.0),
                        dash: index % 8 == 0 ? .pattern(runs: [4, 2], phase: 0) : .solid
                    )
                ))
            case 4, 5, 6:
                let radius = random.double(3, 12)
                var outer: [PDFPoint] = []
                for step in 0..<6 {
                    let angle = 2 * Double.pi * Double(step) / 6
                    outer.append(PDFPoint(
                        x: x + radius * Foundation.cos(angle),
                        y: y + radius * Foundation.sin(angle)
                    ))
                }
                let hole = index % 3 == 0 ? [[
                    PDFPoint(x: x - radius * 0.3, y: y - radius * 0.3),
                    PDFPoint(x: x + radius * 0.3, y: y - radius * 0.3),
                    PDFPoint(x: x + radius * 0.3, y: y + radius * 0.3),
                    PDFPoint(x: x - radius * 0.3, y: y + radius * 0.3)
                ]] : []
                markups.append(RenderableMarkup(
                    id: id,
                    zIndex: index,
                    shape: .filledPolygon(RenderPolygon(outer: outer, holes: hole)),
                    style: RenderStyle(stroke: SceneColors.outline, fill: color, lineWidth: 0.5)
                ))
            case 7, 8:
                markups.append(RenderableMarkup(
                    id: id,
                    zIndex: index,
                    shape: .countSymbol(RenderCountSymbol(
                        center: PDFPoint(x: x, y: y),
                        symbol: CountSymbol.allCases[index % CountSymbol.allCases.count],
                        size: 7
                    )),
                    style: RenderStyle(stroke: color)
                ))
            default:
                markups.append(RenderableMarkup(
                    id: id,
                    zIndex: index,
                    shape: .textLabel(RenderTextLabel(
                        anchorPoint: PDFPoint(x: x, y: y),
                        text: "\(index % 1000)",
                        fontName: "Helvetica",
                        fontSize: 6,
                        anchor: .center
                    )),
                    style: RenderStyle(stroke: SceneColors.label)
                ))
            }
        }
        return (page, markups)
    }
}
