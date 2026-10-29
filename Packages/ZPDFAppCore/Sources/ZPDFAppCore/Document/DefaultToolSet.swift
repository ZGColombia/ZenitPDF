import Foundation
import ZPDFUIPresentation

/// The Tool Library a fresh installation starts with.
///
/// *An empty feature teaches nobody what it is for.* A Tool Library that opens with nothing in
/// it is indistinguishable from one that is broken, and it puts the entire burden of working
/// out what a preset can carry onto the person least equipped to guess — the one who has just
/// installed the application.
///
/// So the six presets below are chosen to demonstrate everything a preset can carry rather
/// than to be a complete construction catalogue, which no six tools could be:
///
/// | Preset | What it shows |
/// |---|---|
/// | Exterior Wall | a wall area with a stored height, and a subject that groups in the ledger |
/// | Interior Wall | the same tool with a different height — a preset is a *decision*, not a tool |
/// | Slab 200 mm | a Volume with a depth and an explicit vertical depth reference (ADR-0004 §2) |
/// | Roof 6:12 | a true sloped area with a magnitude **and** a fall-line azimuth (ADR-0004 §1) |
/// | Door Count | a Count, which is what Place mode drops with one click |
/// | Column Count | a second Count, so the panel opens with a category that has two members |
///
/// # Identity is stable across installations
///
/// Each preset's `UUID` is a constant rather than a fresh one per launch. A built-in that got a
/// new identity every time the application started would be re-adopted as a *different* preset
/// on every open, so the library would grow by six a day, and a project that recorded which
/// preset measured a wall would be pointing at a preset that no longer exists.
///
/// # They are ordinary presets
///
/// Nothing marks them read-only. The estimator's first useful act is usually to change the
/// exterior wall height to the one on their job, and a built-in they cannot edit would be worse
/// than no built-in at all. ``ToolPresetProvenance/builtIn`` records where they came from.
public enum DefaultToolSet {

    /// The category the shipped presets group under.
    public static var category: String {
        NSLocalizedString("Construction", comment: "Category of the built-in tool presets")
    }

    /// The six presets a fresh library starts with, in panel order.
    public static var presets: [ToolPresetSummary] {
        [
            exteriorWall, interiorWall, slab, roof, doorCount, columnCount
        ]
    }

    /// Whether a library already contains the built-in set, by identity.
    ///
    /// Identity rather than name or count, because the estimator is free to rename `Slab 200 mm`
    /// to `Bottenplatta` and free to delete the ones they do not use. Seeding again because a
    /// name changed would put a deleted preset back, which is the one thing a seeding rule must
    /// never do.
    public static func isSeeded(in presets: [ToolPresetSummary]) -> Bool {
        let existing = Set(presets.map(\.id))
        return Self.presets.contains { existing.contains($0.id) }
    }

    /// The library as it should be after seeding.
    ///
    /// Returns `presets` unchanged when any built-in is already present, so this is safe to call
    /// on every open. Seeding happens once, on a library that has never seen the set — which is
    /// also true of an estimator who deleted all six, and that is correct: they said no.
    public static func seeding(_ presets: [ToolPresetSummary]) -> [ToolPresetSummary] {
        guard !isSeeded(in: presets) else { return presets }
        let seeded = Self.presets.enumerated().map { offset, preset -> ToolPresetSummary in
            var copy = preset
            copy.sortIndex = presets.count + offset
            return copy
        }
        return presets + seeded
    }

    // MARK: - The review stamps (NL-PDF-22)

    /// The category the shipped review stamps group under.
    public static var reviewCategory: String {
        NSLocalizedString("Review", comment: "Category of the built-in review stamps")
    }

    /// The six review stamps a library gains once: the words of the standard review cycle,
    /// each with the date, the reviewer and the sheet filled in and frozen when it is placed.
    /// Own wording and no artwork: a border and three lines, sharp at any zoom.
    public static var reviewStamps: [ToolPresetSummary] {
        [
            reviewStamp(1, NSLocalizedString("REVIEWED", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("Reviewed", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.blue),
            reviewStamp(2, NSLocalizedString("APPROVED", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("Approved", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.cyan),
            reviewStamp(3, NSLocalizedString("APPROVED AS NOTED", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("Approved as Noted", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.cyan),
            reviewStamp(4, NSLocalizedString("REVISE AND RESUBMIT", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("Revise and Resubmit", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.danger),
            reviewStamp(5, NSLocalizedString("REJECTED", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("Rejected", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.danger),
            reviewStamp(6, NSLocalizedString("FOR INFORMATION", comment: "Built-in review stamp wording"),
                        name: NSLocalizedString("For Information", comment: "Built-in review stamp"), color: ColorRGBA.Zenit.Light.blue)
        ]
    }

    /// Everything a fresh installation ends up with: the six tools and the six review stamps.
    public static var shipped: [ToolPresetSummary] { presets + reviewStamps }

    /// The library with the review stamps added — once, by identity, independently of the six
    /// tools, so an installation that already had the tools gains the stamps on its next open,
    /// and one whose person deleted every stamp is not given them back.
    public static func seedingReviewStamps(_ presets: [ToolPresetSummary]) -> [ToolPresetSummary] {
        let existing = Set(presets.map(\.id))
        guard !reviewStamps.contains(where: { existing.contains($0.id) }) else { return presets }
        return presets + reviewStamps.enumerated().map { offset, preset -> ToolPresetSummary in
            var copy = preset
            copy.sortIndex = presets.count + offset
            return copy
        }
    }

    private static func reviewStamp(_ number: Int, _ wording: String, name: String, color: ColorRGBA) -> ToolPresetSummary {
        let suffix = String(format: "%012d", 100 + number)
        let id = UUID(uuidString: "1F8B4C2E-0100-4A00-9E00-\(suffix)") ?? UUID()
        func fieldID(_ slot: Int) -> UUID {
            UUID(uuidString: "1F8B4C2E-0200-4A00-9E00-" + String(format: "%012d", number * 10 + slot)) ?? UUID()
        }
        let template = StampTemplate(
            id: id,
            widthPoints: 190,
            heightPoints: 64,
            fields: [
                StampFieldDefinition(
                    id: fieldID(1), kind: .date, dateFormat: "yyyy-MM-dd", textPrefix: wording + " · ",
                    normalizedFrame: PDFRectValue(x: 0.05, y: 0.5, width: 0.9, height: 0.42),
                    fontName: "Helvetica-Bold", fontSizeFraction: 0.26, alignment: .center, colorRGBA: color
                ),
                StampFieldDefinition(
                    id: fieldID(2), kind: .author,
                    textPrefix: NSLocalizedString("By ", comment: "Review stamp prefix before the reviewer's name"),
                    normalizedFrame: PDFRectValue(x: 0.05, y: 0.08, width: 0.55, height: 0.3),
                    fontSizeFraction: 0.18, alignment: .leading, colorRGBA: color
                ),
                StampFieldDefinition(
                    id: fieldID(3), kind: .pageLabel,
                    textPrefix: NSLocalizedString("Sheet ", comment: "Review stamp prefix before the sheet label"),
                    normalizedFrame: PDFRectValue(x: 0.6, y: 0.08, width: 0.35, height: 0.3),
                    fontSizeFraction: 0.18, alignment: .trailing, colorRGBA: color
                )
            ]
        )
        return ToolPresetSummary(
            id: id,
            name: name,
            category: reviewCategory,
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: color,
            defaultSubject: NSLocalizedString("Review", comment: "Built-in review stamp takeoff subject"),
            stamp: template,
            provenance: .builtIn
        )
    }

    // MARK: - The six

    static var exteriorWall: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0001-4A00-9E00-000000000001",
            name: NSLocalizedString("Exterior Wall", comment: "Built-in tool preset"),
            measurementKind: .wallArea,
            color: ColorRGBA.Zenit.Dark.cyan,
            subject: NSLocalizedString("Exterior Wall", comment: "Built-in preset takeoff subject"),
            defaults: .wallHeight(metres: 2.7)
        )
    }

    static var interiorWall: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0002-4A00-9E00-000000000002",
            name: NSLocalizedString("Interior Wall", comment: "Built-in tool preset"),
            measurementKind: .wallArea,
            color: ColorRGBA.Zenit.Dark.blue,
            subject: NSLocalizedString("Interior Wall", comment: "Built-in preset takeoff subject"),
            defaults: .wallHeight(metres: 2.4)
        )
    }

    /// A slab with the depth *and* the depth reference. The reference is the point: a 200 mm
    /// slab measured plumb and a 200 mm slab measured perpendicular to a fall are different
    /// volumes, and ADR-0004 §2 refuses to default the choice.
    static var slab: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0003-4A00-9E00-000000000003",
            name: NSLocalizedString("Slab 200 mm", comment: "Built-in tool preset"),
            measurementKind: .volume,
            color: ColorRGBA.Zenit.Dark.warning,
            subject: NSLocalizedString("Slab", comment: "Built-in preset takeoff subject"),
            defaults: ToolPresetMeasurementDefaults(
                depth: .metres(Decimal(string: "0.2") ?? 0),
                volumeDepthReference: .verticalDepth
            )
        )
    }

    /// A 6:12 pitch is a rise of 6 over a run of 12 — 50 %. The azimuth is stored as 0 degrees,
    /// a fall line running along the page's +x axis, so the preset is complete rather than
    /// carrying a magnitude the engine will refuse to apply to a boundary (ADR-0004 §1). It is
    /// also the first thing an estimator changes, which is exactly the point of storing it.
    static var roof: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0004-4A00-9E00-000000000004",
            name: NSLocalizedString("Roof 6:12", comment: "Built-in tool preset"),
            measurementKind: .trueSlopedArea,
            color: ColorRGBA.Zenit.Dark.danger,
            subject: NSLocalizedString("Roof", comment: "Built-in preset takeoff subject"),
            defaults: ToolPresetMeasurementDefaults(
                slopePercent: 50,
                slopeAzimuthDegrees: 0
            )
        )
    }

    static var doorCount: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0005-4A00-9E00-000000000005",
            name: NSLocalizedString("Door Count", comment: "Built-in tool preset"),
            measurementKind: .count,
            color: ColorRGBA.Zenit.Dark.green,
            subject: NSLocalizedString("Doors", comment: "Built-in preset takeoff subject"),
            defaults: .none,
            // A symbol the renderer can actually draw. `CountSymbolCatalogue` is the only
            // list of those, and a name outside it draws the default dot — which is what the
            // two built-in count presets did from the day they shipped.
            countSymbolName: "square"
        )
    }

    static var columnCount: ToolPresetSummary {
        preset(
            id: "1F8B4C2E-0006-4A00-9E00-000000000006",
            name: NSLocalizedString("Column Count", comment: "Built-in tool preset"),
            measurementKind: .count,
            color: ColorRGBA.Zenit.Dark.selection,
            subject: NSLocalizedString("Columns", comment: "Built-in preset takeoff subject"),
            defaults: .none,
            countSymbolName: "circle.fill"
        )
    }

    // MARK: - Construction

    private static func preset(
        id: String,
        name: String,
        measurementKind: MeasurementKind,
        color: ColorRGBA,
        subject: String,
        defaults: ToolPresetMeasurementDefaults,
        countSymbolName: String? = nil
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            // A constant identifier that will not parse is a programming error, and there is no
            // `fatalError` in this repository. A zero UUID keeps the preset present and visibly
            // wrong rather than making the library disappear.
            id: UUID(uuidString: id) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            name: name,
            category: category,
            panel: .myTools,
            markupKind: measurementKind == .count ? .count : .measurement,
            measurementKind: measurementKind,
            colorRGBA: color,
            defaultSubject: subject,
            measurementDefaults: defaults,
            countSymbolName: countSymbolName,
            provenance: .builtIn
        )
    }
}
