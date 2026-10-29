import Foundation

/// Every fixture in the corpus.
///
/// The raw value is the file's base name, so `ZPDFFixtures.make(.rectangle, in: dir)`
/// writes `dir/rectangle.pdf`. Raw values are part of the contract: FIXTURES.md,
/// golden records and CI logs refer to them, so they are never renamed casually.
public enum FixtureKind: String, Sendable, Codable, Hashable, CaseIterable {

    // MARK: Geometric fixtures with closed-form truth

    /// One straight line whose length is exactly 500 (a 300–400–500 triangle).
    case singleLine = "geo-single-line"
    /// One axis-aligned rectangle.
    case rectangle = "geo-rectangle"
    /// A concave six-vertex L-shape.
    case lShape = "geo-l-shape"
    /// A square with one square hole.
    case polygonOneHole = "geo-polygon-one-hole"
    /// A square with three rectangular holes of different sizes.
    case polygonThreeHoles = "geo-polygon-three-holes"
    /// A circle drawn as four cubic Béziers, with the exact control points recorded.
    case bezierCircle = "geo-bezier-circle"
    /// Two levels of nested form XObjects, each with a non-identity matrix.
    case nestedFormXObjects = "geo-nested-form-xobjects"
    /// Geometry that extends past a rectangular clipping path.
    case clippedContent = "geo-clipped-content"
    /// A full-bleed background rectangle that snap must ignore, plus real geometry.
    case giantBackgroundRectangle = "geo-giant-background-rectangle"
    /// 10 000 short segments on one page, for extraction and snap stress.
    case tenThousandSegments = "geo-ten-thousand-segments"
    /// A structurally valid page whose content stream is a large invalid token soup.
    case hugeMalformedOperatorStream = "geo-huge-malformed-operator-stream"

    // MARK: Page-geometry fixtures

    case rotation0 = "page-rotation-0"
    case rotation90 = "page-rotation-90"
    case rotation180 = "page-rotation-180"
    case rotation270 = "page-rotation-270"
    /// `/CropBox` strictly inside `/MediaBox`.
    case cropBoxSmallerThanMediaBox = "page-crop-smaller-than-media"
    /// Both boxes with a negative lower-left corner.
    case cropBoxNegativeOrigin = "page-crop-negative-origin"
    /// Letter, A4, A1 and ARCH-D in one document.
    case mixedPageSizes = "page-mixed-sizes"
    /// A single ISO A1 sheet, 594 × 841 mm.
    case sizeA1 = "page-size-a1"
    /// A single ARCH-D sheet, 24 × 36 in.
    case sizeArchD = "page-size-arch-d"
    /// 300 uniform Letter pages.
    case threeHundredPages = "page-300-pages"
    /// 1 000 uniform Letter pages, written page by page rather than buffered whole.
    case oneThousandPages = "page-1000-pages"

    // MARK: Content fixtures

    /// A vector drawing sheet with a title block and searchable strings.
    case titleBlockSheet = "content-title-block-sheet"
    /// A rasterised page with no text layer at all.
    case scannedLookPage = "content-scanned-look-page"
    /// A page carrying both a raster block and a real text layer.
    case mixedTextAndRaster = "content-mixed-text-and-raster"
    /// Four optional-content groups — Walls, Doors, a Grid hidden and locked by
    /// default, and a second "Walls" with a deliberately duplicate name — with
    /// `/Order` nesting, one `/RBGroups` radio group, and per-layer page content.
    case threeLayers = "content-three-layers"
    /// Thirty ARCH D sheets (A-101…A-110, S-201…S-210, M-301…M-310) with title blocks,
    /// `/PageLabels`, a three-level `/Outlines` tree, `/Dests`, GoTo / named / URI / JavaScript
    /// `/Link`s, and body text citing other sheets — one of them absent from the set.
    case set30SheetsTitleBlocks = "set-30-sheets-title-blocks"

    // MARK: Synthetic drawing sheets

    /// The Synthetic Roof Plan: one A1 landscape construction sheet drawn from scratch — a hip
    /// roof, a sedum-hatched annex of 4 752 three-stroke glyphs, dash-dot grid axes written one
    /// stroke per dash, a snow-guard strip tied to the eave, three double-frame symbols, a 100 mm
    /// control ruler, two masked raster logos and a fictional title block. Every number a test
    /// asserts is stated in ``SyntheticRoofPlan`` and derived by hand in `FIXTURES.md`.
    case syntheticRoofPlan = "synthetic-roof-plan"
    /// Three sheets for Prepare This Set: the roof plan, a large rooms sheet at 1:100, and the
    /// roof plan again with a rectangle and a line added — pages 1 and 3 draw the same content
    /// stream object.
    case syntheticRoofPlanSet = "synthetic-roof-plan-set"
    /// The roof plan with its sedum hatch on an optional-content group "Hatch" and its grid axes
    /// on "Grid", both visible by default, for the hidden-layer paths.
    case syntheticRoofPlanLayered = "synthetic-roof-plan-layered"
    /// An A1 sheet for Find Walls whose wall classes are derivable by hand: a 250 mm outer wall,
    /// a 120 mm partition with a door, and a hatch of 20 parallel lines 90 mm apart.
    case syntheticWallModule = "synthetic-wall-module"

    // MARK: Hostile fixtures

    /// A valid document cut off mid-body.
    case truncatedFile = "hostile-truncated"
    /// Valid objects, deliberately wrong cross-reference offsets.
    case brokenXref = "hostile-broken-xref"
    /// A `/Pages` node that lists one of its own ancestors as a kid.
    case cyclicPageTree = "hostile-cyclic-page-tree"
    /// A page that references an object number the file does not contain.
    case missingObject = "hostile-missing-object"
    /// 100 levels of form XObjects, each drawing the next.
    case deeplyNestedForms = "hostile-deeply-nested-forms"
    /// A small file whose page content stream inflates to 64 MiB.
    case decompressionBomb = "hostile-decompression-bomb"
    /// Standard-security encryption with a known user password.
    case encryptedUserPassword = "hostile-encrypted-user-password"
    /// An embedded file plus a `/Launch` action.
    case embeddedFileWithLaunchAction = "hostile-embedded-file-launch-action"
    /// A document-level `/JavaScript` name tree and an `/OpenAction`.
    case javaScriptAction = "hostile-javascript"
    /// A well-formed page whose `/OCProperties /OCGs` references a missing object.
    case brokenLayerReference = "hostile-broken-layer-reference"

    /// The file name written by `ZPDFFixtures.make(_:in:)`.
    public var fileName: String { "\(rawValue).pdf" }

    /// The fixtures that carry closed-form geometric truth.
    public static var geometric: [FixtureKind] {
        [
            .singleLine, .rectangle, .lShape, .polygonOneHole, .polygonThreeHoles,
            .bezierCircle, .nestedFormXObjects, .clippedContent,
            .giantBackgroundRectangle, .tenThousandSegments,
            .hugeMalformedOperatorStream
        ]
    }

    /// The fixtures that exercise page boxes, rotation and page counts.
    public static var pageGeometry: [FixtureKind] {
        [
            .rotation0, .rotation90, .rotation180, .rotation270,
            .cropBoxSmallerThanMediaBox, .cropBoxNegativeOrigin, .mixedPageSizes,
            .sizeA1, .sizeArchD, .threeHundredPages, .oneThousandPages
        ]
    }

    /// The fixtures that exercise text, raster and mixed content.
    public static var content: [FixtureKind] {
        [.titleBlockSheet, .scannedLookPage, .mixedTextAndRaster, .threeLayers, .set30SheetsTitleBlocks]
    }

    /// The synthetic drawing sheets that stand in for a real construction drawing.
    public static var syntheticSheets: [FixtureKind] {
        [.syntheticRoofPlan, .syntheticRoofPlanSet, .syntheticRoofPlanLayered, .syntheticWallModule]
    }

    /// The fixtures that are deliberately malformed, hostile or dangerous.
    public static var hostile: [FixtureKind] {
        [
            .truncatedFile, .brokenXref, .cyclicPageTree, .missingObject,
            .deeplyNestedForms, .decompressionBomb, .encryptedUserPassword,
            .embeddedFileWithLaunchAction, .javaScriptAction, .brokenLayerReference
        ]
    }

    /// `true` when the file is a conforming PDF that any reader must be able to open.
    ///
    /// The hostile fixtures that remain structurally openable — the bomb, the
    /// encrypted file, the embedded-file and JavaScript documents — are deliberately
    /// valid: their danger is in what a reader does after opening them.
    public var isStructurallyValid: Bool {
        switch self {
        case .truncatedFile, .brokenXref, .cyclicPageTree, .missingObject:
            return false
        default:
            return true
        }
    }
}
