import Foundation

/// Fixtures whose subject is optional content: PDF layers (`/OCProperties`, OCGs),
/// the default configuration, and marked-content membership in the page stream.
enum LayerFixtures {

    static let page = FixturePageSize.letter
    static let strokeWidth: Double = 1.0

    // MARK: - Geometry constants

    /// Unlayered content: a 300–400–500 line, so the length is exact in binary.
    static let unlayeredStart = FixturePoint(50, 50)
    static let unlayeredEnd = FixturePoint(350, 450)

    /// On "Walls" (visible by default): an axis-aligned rectangle.
    static let wallsRect = FixtureRect(x: 100, y: 600, width: 200, height: 100)

    /// On "Doors" (visible by default): a horizontal line of length 300.
    static let doorsStart = FixturePoint(100, 200)
    static let doorsEnd = FixturePoint(400, 200)

    /// On "Grid" (hidden by default, locked): a horizontal line of length 300.
    static let gridStart = FixturePoint(100, 300)
    static let gridEnd = FixturePoint(400, 300)

    /// On the second layer also named "Walls" (duplicate name, visible).
    static let duplicateStart = FixturePoint(100, 400)
    static let duplicateEnd = FixturePoint(400, 400)

    // MARK: - content-three-layers

    /// A one-page document with four optional-content groups:
    ///
    /// | `/OCGs` index | Name  | Default | Locked | Notes |
    /// |---|---|---|---|---|
    /// | 0 | Walls | on  | no  | `/Order` parent of Doors |
    /// | 1 | Doors | on  | no  | nested under Walls, radio group with Grid |
    /// | 2 | Grid  | off | yes | `/Usage` view and print both `/OFF` |
    /// | 3 | Walls | on  | no  | deliberate duplicate name |
    ///
    /// The page's `/Resources /Properties` maps `/L0…/L3` to the groups in that order,
    /// and each group's geometry sits inside a `BDC /OC` section using that name.
    /// One line is drawn outside any marked-content section.
    static func threeLayers() throws -> FixtureBuild {
        let unlayered = FixturePath(
            id: "unlayered-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [unlayeredStart, unlayeredEnd],
            length: 500,
            area: 0,
            derivation: .closedForm(
                "Pythagoras: sqrt((350-50)^2 + (450-50)^2) = sqrt(300^2 + 400^2) = 500. "
                    + "A 3-4-5 triple, exact in binary floating point.",
                magnitudeFloor: 500
            )
        )
        let walls = FixturePath(
            id: "walls-rectangle",
            pageIndex: 0,
            kind: .closedPolygon,
            points: wallsRect.counterClockwiseCorners,
            length: 2 * (200 + 100),
            area: 200 * 100,
            derivation: .closedForm(
                "Rectangle 200 x 100 at (100, 600). Area = 200*100 = 20000, "
                    + "perimeter = 2*(200+100) = 600.",
                conditionNumber: 7.5,
                magnitudeFloor: 20_000
            ),
            notes: ["Drawn inside BDC /OC /L0 (layer 'Walls', visible by default)."]
        )
        let doors = FixturePath(
            id: "doors-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [doorsStart, doorsEnd],
            length: 300,
            area: 0,
            derivation: .closedForm(
                "Horizontal segment from x=100 to x=400 at y=200: length 400-100 = 300.",
                magnitudeFloor: 300
            ),
            notes: ["Drawn inside BDC /OC /L1 (layer 'Doors', visible by default)."]
        )
        let grid = FixturePath(
            id: "grid-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [gridStart, gridEnd],
            length: 300,
            area: 0,
            derivation: .closedForm(
                "Horizontal segment from x=100 to x=400 at y=300: length 400-100 = 300.",
                magnitudeFloor: 300
            ),
            notes: ["Drawn inside BDC /OC /L2 (layer 'Grid', OFF by default and locked)."]
        )
        let duplicate = FixturePath(
            id: "duplicate-walls-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [duplicateStart, duplicateEnd],
            length: 300,
            area: 0,
            derivation: .closedForm(
                "Horizontal segment from x=100 to x=400 at y=400: length 400-100 = 300.",
                magnitudeFloor: 300
            ),
            notes: ["Drawn inside BDC /OC /L3 (second layer named 'Walls' — duplicate name)."]
        )

        let manifest = FixtureManifest(
            kind: .threeLayers,
            title: "Optional-content layers: Walls, Doors, hidden Grid, duplicate Walls",
            purpose: "Layer tree parsing, default visibility, lock state, /Order nesting, "
                + "/RBGroups, duplicate names, and layer-aware snap filtering.",
            fileName: FixtureKind.threeLayers.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [unlayered, walls, doors, grid, duplicate],
            notes: [
                "OCGs in /OCProperties order: Walls, Doors, Grid, Walls (duplicate name).",
                "Grid is in /D /OFF and /D /Locked; its /Usage sets /ViewState /OFF and /PrintState /OFF.",
                "/D /Order nests Doors under Walls: [Walls [Doors] Grid Walls].",
                "/D /RBGroups declares one radio group: [Doors Grid]. /RBGroups belongs in the "
                    + "configuration dictionary (PDF 32000-1 Table 101), so that is where it is written.",
                "Page 0 /Resources /Properties: /L0 Walls, /L1 Doors, /L2 Grid, /L3 duplicate Walls.",
                "One line is unlayered (never inside a BDC /OC section)."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .threeLayers)
            let wallsOCG = builder.addObject("<< /Type /OCG /Name (Walls) >>")
            let doorsOCG = builder.addObject("<< /Type /OCG /Name (Doors) >>")
            let gridOCG = builder.addObject(
                "<< /Type /OCG /Name (Grid) /Usage << /View << /ViewState /OFF >> "
                    + "/Print << /PrintState /OFF >> >> >>"
            )
            let duplicateOCG = builder.addObject("<< /Type /OCG /Name (Walls) >>")

            builder.catalogExtraEntries =
                "/OCProperties << "
                + "/OCGs [\(wallsOCG) 0 R \(doorsOCG) 0 R \(gridOCG) 0 R \(duplicateOCG) 0 R] "
                + "/D << /Order [\(wallsOCG) 0 R [\(doorsOCG) 0 R] \(gridOCG) 0 R \(duplicateOCG) 0 R] "
                + "/OFF [\(gridOCG) 0 R] /Locked [\(gridOCG) 0 R] "
                + "/RBGroups [[\(doorsOCG) 0 R \(gridOCG) 0 R]] >> >>"

            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)

            // Unlayered content first, outside any marked-content section.
            content.move(to: unlayeredStart)
            content.line(to: unlayeredEnd)
            content.stroke()

            content.raw("/OC /L0 BDC")
            content.appendRectangle(wallsRect)
            content.stroke()
            content.raw("EMC")

            content.raw("/OC /L1 BDC")
            content.move(to: doorsStart)
            content.line(to: doorsEnd)
            content.stroke()
            content.raw("EMC")

            content.raw("/OC /L2 BDC")
            content.move(to: gridStart)
            content.line(to: gridEnd)
            content.stroke()
            content.raw("EMC")

            content.raw("/OC /L3 BDC")
            content.move(to: duplicateStart)
            content.line(to: duplicateEnd)
            content.stroke()
            content.raw("EMC")

            let contents = try builder.addContentStream(content)
            let resources = "<< /Properties << "
                + "/L0 \(wallsOCG) 0 R /L1 \(doorsOCG) 0 R "
                + "/L2 \(gridOCG) 0 R /L3 \(duplicateOCG) 0 R >> >>"
            builder.addPage(mediaBox: page, resources: resources, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - hostile-broken-layer-reference

    /// A structurally valid document whose `/OCProperties /OCGs` array holds one
    /// indirect reference to an object the file does not contain. CoreGraphics opens
    /// the file and renders the page; only the layer catalogue is broken, and a layer
    /// reader must fail with a typed error rather than trap or invent a layer.
    static func brokenLayerReference() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .brokenLayerReference,
            title: "OCProperties whose /OCGs references a missing object",
            purpose: "A layer catalogue with a broken reference must produce a typed error, "
                + "never a trap and never a phantom layer.",
            fileName: FixtureKind.brokenLayerReference.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.brokenLayerReference],
            notes: [
                "/OCProperties << /OCGs [999 0 R] /D << >> >> where object 999 does not exist.",
                "The page itself is well-formed and must open normally."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .brokenLayerReference)
            builder.catalogExtraEntries = "/OCProperties << /OCGs [999 0 R] /D << >> >>"
            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.appendRectangle(FixtureRect(x: 100, y: 100, width: 200, height: 100))
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }
}
