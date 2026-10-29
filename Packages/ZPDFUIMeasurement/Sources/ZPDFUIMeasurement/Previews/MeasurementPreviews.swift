#if DEBUG
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Preview fixtures for the measurement surfaces.
///
/// Deliberately hand-built rather than random: the same numbers appear in every preview, so a
/// visual change is a change in the view and never in the data.
enum MeasurementPreviewData {

    static let scale = ScaleSummary(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID(),
        name: NSLocalizedString("Plan 1:50", comment: "Preview scale name"),
        displayString: "1:50",
        isUniform: true,
        sx: 0.017_638_9,
        sy: 0.017_638_9,
        unit: .metre,
        version: 3,
        locked: false
    )

    static let detailScale = ScaleSummary(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2") ?? UUID(),
        name: NSLocalizedString("Stair detail 1:20", comment: "Preview scale name"),
        displayString: "1:20",
        isUniform: true,
        sx: 0.007_055_6,
        sy: 0.007_055_6,
        unit: .metre,
        version: 1,
        locked: true
    )

    static let pageID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1") ?? UUID()

    static let regions: [ScaleRegionSummary] = [
        ScaleRegionSummary(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID(),
            name: NSLocalizedString("Stair Detail", comment: "Preview region name"),
            pageID: pageID,
            pageLabel: "A-201",
            scale: detailScale,
            boundary: [
                PDFPointValue(x: 120, y: 400),
                PDFPointValue(x: 320, y: 400),
                PDFPointValue(x: 320, y: 560),
                PDFPointValue(x: 120, y: 560)
            ],
            priority: 20,
            locked: true,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan
        ),
        ScaleRegionSummary(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2") ?? UUID(),
            name: NSLocalizedString("Main Floor Plan", comment: "Preview region name"),
            pageID: pageID,
            pageLabel: "A-201",
            scale: scale,
            boundary: [
                PDFPointValue(x: 60, y: 80),
                PDFPointValue(x: 700, y: 80),
                PDFPointValue(x: 700, y: 620),
                PDFPointValue(x: 60, y: 620)
            ],
            priority: 10,
            locked: false,
            colorRGBA: ColorRGBA.Zenit.Dark.blue
        )
    ]

    static let overlap = ScaleRegionOverlap(
        first: regions[1].id,
        second: regions[0].id,
        firstName: regions[1].name,
        secondName: regions[0].name
    )

    static let crossing = ScaleRegionCrossing(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1") ?? UUID(),
        measurementName: MeasurementKind.area.displayName,
        pageLabel: "A-201",
        regions: regions,
        canSplitAtBoundary: true,
        pageDefaultScale: scale
    )

    static let candidates: [SnapFeedbackSnapshot] = [
        SnapFeedbackSnapshot(
            kind: .intersection,
            pagePoint: PDFPointValue(x: 210, y: 300),
            sourceLabel: NSLocalizedString("Wall centreline", comment: "Preview snap source"),
            guideHint: SnapGuideHint(
                text: NSLocalizedString("Horizontal", comment: "Preview guide hint"),
                start: PDFPointValue(x: 120, y: 300),
                end: PDFPointValue(x: 320, y: 300),
                angleDegrees: 0
            ),
            pageID: pageID,
            confidence: 0.94
        ),
        SnapFeedbackSnapshot(
            kind: .endpoint,
            pagePoint: PDFPointValue(x: 210, y: 300),
            sourceLabel: NSLocalizedString("Door jamb", comment: "Preview snap source"),
            pageID: pageID,
            confidence: 0.81
        ),
        SnapFeedbackSnapshot(
            kind: .grid,
            pagePoint: PDFPointValue(x: 212, y: 302),
            sourceLabel: NSLocalizedString("Grid 250 mm", comment: "Preview snap source"),
            pageID: pageID,
            confidence: 0.5
        )
    ]

    static var calibrationDraft: CalibrationDraft {
        CalibrationDraft(
            mode: .uniform,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 120, y: 200),
                end: PDFPointValue(x: 460, y: 200),
                knownLength: 6
            ),
            unitIdentifier: LengthUnit.metre.rawValue,
            name: NSLocalizedString("Plan 1:50", comment: "Preview scale name")
        )
    }

    static let impact = BulkScaleImpact(
        pageCount: 12,
        markupCount: 348,
        affectedMeasurementCount: 291,
        lockedPageCount: 1,
        pageLabels: ["A-101", "A-102", "A-201", "A-202", "A-203"]
    )
}

/// A neutral ground so a preview looks like the app rather than a blank sheet.
private struct PreviewGround<Content: View>: View {
    let title: String
    var width: CGFloat = 520
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(title).zpdfText(.sectionHeader, .textSecondary).textCase(.uppercase)
            content
        }
        .padding(ZPDFSpacing.xl)
        .frame(width: width)
        .background(ZPDFColor.background)
    }
}

struct CalibrationSheet_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var draft = MeasurementPreviewData.calibrationDraft

        var body: some View {
            CalibrationSheet(draft: $draft, pageLabel: "A-201")
        }
    }

    static var previews: some View {
        Group {
            Demo().preferredColorScheme(.dark).previewDisplayName("Calibration - dark")
            Demo().preferredColorScheme(.light).previewDisplayName("Calibration - light")
        }
    }
}

struct ScaleRegionsPanel_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var selection: UUID? = MeasurementPreviewData.regions.first?.id

        var body: some View {
            ScaleRegionsPanel(
                regions: MeasurementPreviewData.regions,
                pageDefaultScale: MeasurementPreviewData.scale,
                overlaps: [MeasurementPreviewData.overlap],
                crossing: MeasurementPreviewData.crossing,
                selection: $selection
            )
            .frame(width: 520, height: 620)
        }
    }

    static var previews: some View {
        Demo().preferredColorScheme(.dark).previewDisplayName("Scale Regions")
    }
}

struct BulkScaleSheet_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var selection = BulkScaleSelection(kind: .matchingDimensions)

        var body: some View {
            BulkScaleSheet(
                scale: MeasurementPreviewData.scale,
                pageCount: 24,
                currentPageLabel: "A-201",
                selection: $selection,
                impact: MeasurementPreviewData.impact
            )
        }
    }

    static var previews: some View {
        Demo().preferredColorScheme(.dark).previewDisplayName("Bulk scale")
    }
}

struct MeasurementLoupe_Previews: PreviewProvider {
    static var previews: some View {
        PreviewGround(title: "Loupe", width: 260) {
            MeasurementLoupe(
                pagePoint: PDFPointValue(x: 210.25, y: 300.75),
                magnification: 6,
                snapCandidate: MeasurementPreviewData.candidates[0],
                scale: MeasurementPreviewData.scale
            ) {
                ZStack {
                    ZPDFColor.canvasBackdrop
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 66))
                        path.addLine(to: CGPoint(x: 132, y: 66))
                        path.move(to: CGPoint(x: 66, y: 0))
                        path.addLine(to: CGPoint(x: 66, y: 132))
                    }
                    .stroke(ZPDFColor.textSecondary, lineWidth: 1)
                }
            }
        }
        .preferredColorScheme(.dark)
        .previewDisplayName("Measurement loupe")
    }
}
#endif
