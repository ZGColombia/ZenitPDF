import Foundation

/// Maps a `FixtureKind` to the code that produces it.
enum FixtureRegistry {

    /// Bumped whenever a fixture's bytes change. On-disk caches record it, so a stale
    /// file from an earlier version of the generator is regenerated rather than reused.
    /// The stamp also carries the manifest's digest, so an edit that moves a manifest
    /// value invalidates the cache even if this is forgotten; a bytes-only edit does not.
    ///
    /// 2: `/RBGroups` in `/D`, explicit `/Rotate 0`, the decompression
    /// bomb padded to exactly 64 MiB, and the content-digest stamp format.
    /// 3: the synthetic drawing sheets (``SyntheticRoofPlan``) join the corpus.
    static let generatorVersion = 3

    static func build(_ kind: FixtureKind) throws -> FixtureBuild {
        switch kind {
        // Geometric
        case .singleLine: return try GeometricFixtures.singleLine()
        case .rectangle: return try GeometricFixtures.rectangle()
        case .lShape: return try GeometricFixtures.lShape()
        case .polygonOneHole: return try GeometricFixtures.polygonOneHole()
        case .polygonThreeHoles: return try GeometricFixtures.polygonThreeHoles()
        case .bezierCircle: return try GeometricFixtures.bezierCircle()
        case .nestedFormXObjects: return try GeometricFixtures.nestedFormXObjects()
        case .clippedContent: return try GeometricFixtures.clippedContent()
        case .giantBackgroundRectangle: return try GeometricFixtures.giantBackgroundRectangle()
        case .tenThousandSegments: return try GeometricFixtures.tenThousandSegments()
        case .hugeMalformedOperatorStream: return try GeometricFixtures.hugeMalformedOperatorStream()

        // Page geometry
        case .rotation0: return try PageGeometryFixtures.rotation(0)
        case .rotation90: return try PageGeometryFixtures.rotation(90)
        case .rotation180: return try PageGeometryFixtures.rotation(180)
        case .rotation270: return try PageGeometryFixtures.rotation(270)
        case .cropBoxSmallerThanMediaBox: return try PageGeometryFixtures.cropBoxSmallerThanMediaBox()
        case .cropBoxNegativeOrigin: return try PageGeometryFixtures.cropBoxNegativeOrigin()
        case .mixedPageSizes: return try PageGeometryFixtures.mixedPageSizes()
        case .sizeA1:
            return try PageGeometryFixtures.singleSheet(
                .sizeA1, box: FixturePageSize.a1, label: "ISO A1 sheet, 594 x 841 mm"
            )
        case .sizeArchD:
            return try PageGeometryFixtures.singleSheet(
                .sizeArchD, box: FixturePageSize.archD, label: "ARCH D sheet, 24 x 36 in"
            )
        case .threeHundredPages: return try PageGeometryFixtures.manyPages(.threeHundredPages, pageCount: 300)
        case .oneThousandPages: return try PageGeometryFixtures.manyPages(.oneThousandPages, pageCount: 1_000)

        // Content
        case .titleBlockSheet: return try ContentFixtures.titleBlockSheet()
        case .scannedLookPage: return try ContentFixtures.scannedLookPage()
        case .mixedTextAndRaster: return try ContentFixtures.mixedTextAndRaster()
        case .threeLayers: return try LayerFixtures.threeLayers()
        case .set30SheetsTitleBlocks: return try SheetSetFixtures.thirtySheets()

        // Synthetic drawing sheets
        case .syntheticRoofPlan: return try SyntheticRoofPlanFixtures.roofPlan()
        case .syntheticRoofPlanSet: return try SyntheticRoofPlanFixtures.threeSheetSet()
        case .syntheticRoofPlanLayered: return try SyntheticRoofPlanFixtures.layered()
        case .syntheticWallModule: return try SyntheticRoofPlanFixtures.wallModule()

        // Hostile
        case .truncatedFile: return try HostileFixtures.truncatedFile()
        case .brokenXref: return try HostileFixtures.brokenXref()
        case .cyclicPageTree: return try HostileFixtures.cyclicPageTree()
        case .missingObject: return try HostileFixtures.missingObject()
        case .deeplyNestedForms: return try HostileFixtures.deeplyNestedForms()
        case .decompressionBomb: return try HostileFixtures.decompressionBomb()
        case .encryptedUserPassword: return try HostileFixtures.encryptedUserPassword()
        case .embeddedFileWithLaunchAction: return try HostileFixtures.embeddedFileWithLaunchAction()
        case .javaScriptAction: return try HostileFixtures.javaScriptAction()
        case .brokenLayerReference: return try LayerFixtures.brokenLayerReference()
        }
    }
}
