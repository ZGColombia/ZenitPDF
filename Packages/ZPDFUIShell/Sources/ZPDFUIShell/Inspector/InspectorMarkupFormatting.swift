import Foundation
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation

/// What the Inspector's header card says about the selection: a glyph, a title and one
/// secondary line.
///
/// Built from the selection only, so the card never shows a value the document does not hold.
/// Value-only and testable without a view tree.
public struct InspectorHeaderModel: Equatable, Sendable {

    /// The glyph drawn on the accent tile.
    public let glyph: ZPDFGlyph
    /// "Area Measurement", "Callout", or "3 markups selected".
    public let title: String
    /// "Floor Screed · Page A-101", the type for a multi-selection, or `nil`.
    public let subtitle: String?

    public init(glyph: ZPDFGlyph, title: String, subtitle: String?) {
        self.glyph = glyph
        self.title = title
        self.subtitle = subtitle
    }

    /// The card for a selection. `nil` when nothing is selected — the panel shows its empty
    /// state instead.
    public init?(summary: InspectorSelectionSummary) {
        guard !summary.isEmpty else { return nil }
        if let markup = summary.single {
            glyph = Self.glyph(for: markup)
            title = Self.typeName(for: markup)
            var parts: [String] = []
            let subject = markup.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !subject.isEmpty { parts.append(subject) }
            let page = markup.pageLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty {
                parts.append(String(
                    format: NSLocalizedString("Page %@", comment: "Inspector header card: the page the markup is on"),
                    page
                ))
            }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            let kinds = Set(summary.markups.map(\.kind))
            let measurementKinds = Set(summary.markups.map(\.measurementKind))
            if kinds.count == 1, measurementKinds.count == 1, let first = summary.markups.first {
                glyph = Self.glyph(for: first)
            } else {
                glyph = .symbol(.inspector)
            }
            title = summary.headerTitle
            subtitle = summary.headerSubtitle
        }
    }

    /// "Area Measurement" for a measurement, the markup type's own name otherwise.
    public static func typeName(for markup: MarkupSummary) -> String {
        guard let measurementKind = markup.measurementKind else { return markup.kind.displayName }
        return String(
            format: NSLocalizedString(
                "%@ Measurement",
                comment: "Inspector header card title for a measurement; the placeholder is the tool name, e.g. Area"
            ),
            measurementKind.displayName
        )
    }

    /// The tile glyph for one markup: the measurement tool's own glyph where the icon set has
    /// one, a markup-type symbol otherwise.
    public static func glyph(for markup: MarkupSummary) -> ZPDFGlyph {
        if let measurementKind = markup.measurementKind {
            switch measurementKind {
            case .length, .dimension, .temporaryMeasure, .trueSlopedLength: return .measurement(.length)
            case .polylength: return .measurement(.polylength)
            case .perimeter: return .measurement(.perimeter)
            case .area, .trueSlopedArea: return .measurement(.area)
            case .rectangleArea: return .measurement(.rectangleArea)
            case .ellipseArea: return .measurement(.ellipseArea)
            case .polygonCutout, .ellipseCutout: return .measurement(.cutout)
            case .volume: return .measurement(.volume)
            case .wallArea: return .measurement(.wallArea)
            case .count: return .measurement(.count)
            case .radius, .threePointCircle: return .measurement(.radius)
            case .diameter: return .measurement(.diameter)
            case .angle: return .measurement(.angle)
            case .slope, .riseDrop: return .measurement(.slope)
            case .arcLength: return .measurement(.arc)
            }
        }
        switch markup.kind {
        case .text, .note, .highlight, .underline, .strikeout, .hyperlink: return .symbol(.text)
        case .callout, .issue: return .symbol(.callout)
        case .count: return .measurement(.count)
        case .measurement: return .symbol(.measure)
        case .stamp, .image: return .symbol(.duplicate)
        case .freehand, .line, .arrow, .polyline, .rectangle, .ellipse, .polygon, .cloud, .revisionCloud:
            return .symbol(.shapes)
        }
    }
}

/// Small, value-only formatting rules the Markup tab uses.
enum InspectorMarkupFormatting {

    // MARK: - Author

    /// Up to two initials for an avatar: "John Doe" → "JD", "anna" → "A", "" → "?".
    ///
    /// The one ``AuthorInitials`` rule the top bar's badge uses too (S-053): letters only,
    /// uppercased in the given locale, so "Å. Öberg" reads "ÅÖ"; an e-mail-shaped author name
    /// uses its local part, so "a.berg@site.example" reads "AB". A name with no letters
    /// draws "?" in the avatar.
    static func initials(for author: String, locale: Locale = .current) -> String {
        let initials = AuthorInitials.initials(for: author, locale: locale)
        return initials.isEmpty ? "?" : initials
    }

    // MARK: - Secondary unit

    /// The measured value restated in the other unit system — "57.6 m²" under "620.0 ft²",
    /// "30.48 m" under "100' - 0\"" — or `nil` when there is nothing honest to say.
    ///
    /// `nil` for counts, ratios, angles and any dimension without a unit on both sides; for a
    /// field some selected markup lacks; for markups displayed in different units; and for
    /// several markups that are neither totalled nor shown at one value. The sum runs in
    /// `Decimal` over the stored SI quantities and is rounded only here, at display.
    ///
    /// - Parameter isTotal: the row's own decision (``InspectorMeasurementModel/ValueRow/isTotal``)
    ///   — whether the primary value beside this one is the sum over the selection. X-022: this
    ///   used to decide on its own and summed every multi-selection, so three 12'-6" walls, whose
    ///   primary reads one wall (a feet-and-inches text has no total), were restated as 11.43 m —
    ///   three walls beside one.
    static func secondaryText(
        for field: MeasurementField,
        isTotal: Bool,
        in summary: InspectorSelectionSummary,
        locale: Locale = .current
    ) -> String? {
        let fields = summary.markups.compactMap { $0.field(field) }
        guard !fields.isEmpty, fields.count == summary.markups.count, let first = fields.first else { return nil }
        let symbol = first.displayUnitSymbol
        guard fields.allSatisfy({ $0.displayUnitSymbol == symbol }) else { return nil }
        // A total restates the total — the one ``InspectorSelectionSummary/summedQuantity(_:)``
        // sums, repeats counted as the ledger counts them (W-040). Any other row restates the one
        // value its primary shows: one markup's own one-instance value, or the value several
        // markups share; several that differ show "Multiple values", which has nothing to restate.
        let total: DecimalQuantity
        if isTotal {
            guard let sum = summary.summedQuantity(field) else { return nil }
            total = sum
        } else {
            guard fields.allSatisfy({ $0.displayText == first.displayText }) else { return nil }
            total = first.quantity
        }
        let converted: Decimal
        let targetSymbol: String
        switch field.dimension {
        case .length:
            guard let shown = LengthUnit(rawValue: symbol) else { return nil }
            let target: LengthUnit = shown.isMetric ? .foot : .metre
            guard let value = try? total.converted(to: target) else { return nil }
            converted = value
            targetSymbol = target.rawValue
        case .area:
            guard let shown = AreaUnit(rawValue: symbol) else { return nil }
            let target: AreaUnit = metricAreaUnits.contains(shown) ? .squareFoot : .squareMetre
            guard let value = try? total.converted(to: target) else { return nil }
            converted = value
            targetSymbol = target.rawValue
        case .volume:
            guard let shown = VolumeUnit(rawValue: symbol) else { return nil }
            let target: VolumeUnit = metricVolumeUnits.contains(shown) ? .cubicFoot : .cubicMetre
            guard let value = try? total.converted(to: target) else { return nil }
            converted = value
            targetSymbol = target.rawValue
        default:
            return nil
        }
        // At most two decimals, trailing zeros dropped, rounded once half away from zero. The
        // restated value uses the decimal mark the primary value is printed with, read in the
        // document's number locale (R-070): the locale's own mark renders through the ledger's
        // formatter, grouping included, exactly like the rows; another locale's mark — a text the
        // locale did not write — is borrowed without grouping, so "27,45 m²" is never followed by
        // "295.47 ft²". It used to take the last "." or "," as the mark, so English "12,345 m²"
        // lent its grouping comma to the restated value as a decimal separator.
        let rounded = LedgerNumberFormatting.rounded(converted, fractionDigits: 2)
        let reading = InspectorDisplayedNumber.read(first.displayText, locale: locale)
        let number = InspectorDisplayedNumber(
            decimalMark: reading?.decimalMark,
            fractionDigits: Self.significantFractionDigits(of: rounded)
        ).render(rounded, locale: locale)
        return "\(number) \(targetSymbol)"
    }

    /// The fraction digits a value actually carries, trailing zeros ignored.
    static func significantFractionDigits(of value: Decimal) -> Int {
        let plain = value.description
        guard let dot = plain.firstIndex(of: ".") else { return 0 }
        return plain[plain.index(after: dot)...].reversed().drop(while: { $0 == "0" }).count
    }

    static let metricAreaUnits: Set<AreaUnit> = [
        .squareMillimetre, .squareCentimetre, .squareMetre, .hectare, .squareKilometre
    ]
    static let metricVolumeUnits: Set<VolumeUnit> = [.cubicCentimetre, .cubicMetre, .litre]

    // MARK: - Fill

    /// The fill alpha the canvas derives for a closed area stored without a fill, and the
    /// alpha a fill picked for such a markup starts from — the one shared constant
    /// `CanvasPageView` draws with.
    static let derivedFillAlpha = MarkupFillDefaults.derivedAreaFillAlpha

    /// Whether the canvas tints this markup's interior even when it stores no fill: the
    /// polygon- and circle-shaped areas and the rectangle and polygon shapes.
    static func derivesFill(_ markup: MarkupSummary) -> Bool {
        if let tool = markup.measurementKind {
            switch tool {
            case .area, .rectangleArea, .ellipseArea, .trueSlopedArea, .volume, .perimeter: return true
            default: return false
            }
        }
        return markup.kind == .rectangle || markup.kind == .polygon
    }

    /// Whether the markup has an interior a fill colours: every kind that derives a fill, plus
    /// the ellipse, cloud, callout box and stamp, which draw a stored fill and nothing otherwise.
    static func acceptsFill(_ markup: MarkupSummary) -> Bool {
        // A Text box takes a fill since ADR-0029 (NL-MARKUP-08).
        derivesFill(markup) || [.ellipse, .cloud, .callout, .stamp, .text].contains(markup.kind)
    }

    /// The fill the canvas actually draws for a markup: the stored fill, the derived stroke
    /// tint (20 %) for a closed area without one, or `nil` for an unfilled markup.
    static func effectiveFill(_ markup: MarkupSummary) -> ColorRGBA? {
        if let fill = markup.fillRGBA { return fill }
        guard derivesFill(markup) else { return nil }
        var tint = markup.colorRGBA
        tint.alpha = markup.colorRGBA.alpha * derivedFillAlpha
        return tint
    }

    // MARK: - Lock and visibility

    /// What the ⋯ menu's lock item does: unlock when every selected markup is locked, lock
    /// otherwise (a partly locked selection locks the rest — `setLocked` never refuses).
    static func lockTarget(_ summary: InspectorSelectionSummary) -> Bool {
        !(summary.markups.allSatisfy(\.locked) && !summary.isEmpty)
    }

    static func lockTitle(_ summary: InspectorSelectionSummary) -> String {
        lockTarget(summary)
            ? NSLocalizedString("Lock", comment: "Inspector header menu: lock the selection")
            : NSLocalizedString("Unlock", comment: "Inspector header menu: unlock the selection")
    }

    /// What the visibility item does: show when every selected markup is hidden, hide otherwise.
    static func hideTarget(_ summary: InspectorSelectionSummary) -> Bool {
        !(summary.markups.allSatisfy(\.hidden) && !summary.isEmpty)
    }

    static func hideTitle(_ summary: InspectorSelectionSummary) -> String {
        hideTarget(summary)
            ? NSLocalizedString("Hide", comment: "Inspector header menu: hide the selection")
            : NSLocalizedString("Show", comment: "Inspector header menu: show the selection")
    }

    /// Whether the visibility item can run. `setHidden` refuses the whole command when a
    /// locked markup would change visibility, so the item is off rather than a promise the
    /// engine breaks.
    static func canChangeVisibility(_ summary: InspectorSelectionSummary) -> Bool {
        let target = hideTarget(summary)
        return !summary.isEmpty && !summary.markups.contains { $0.locked && $0.hidden != target }
    }

    // MARK: - Review status

    /// The value the bulk-edit path stores for a review status.
    ///
    /// Since NL-COLLAB-03 the presentation tier has the document's eight states with the
    /// document's raw values, so the stored value is the raw value, one to one.
    static func storedStatusValue(_ status: MarkupStatus) -> String {
        status.rawValue
    }

    /// The severity a review status is tinted with — a redundant cue beside its name.
    static func severity(for status: MarkupStatus) -> ZPDFSeverity {
        switch status {
        case .accepted, .completed, .resolved: return .success
        case .rejected: return .danger
        case .inProgress: return .warning
        case .open: return .info
        case .none, .cancelled: return .neutral
        }
    }

    // MARK: - Timestamps

    /// A timestamp as the mockup sets it: the date and the time as two strings, so the view
    /// can space them apart.
    @MainActor
    static func dateAndTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> (date: String, time: String) {
        let pair = timestampFormatters(locale: locale, timeZone: timeZone)
        return (pair.day.string(from: date), pair.clock.string(from: date))
    }

    /// The two formatters for one locale and time zone, made once (R-082).
    ///
    /// `dateAndTime` runs for Created and Modified on every Inspector render and for every
    /// thread item on the Comments tab; it allocated two `DateFormatter`s per call. Keyed by
    /// the locale's and the zone's identifiers, so a change of either builds a fresh pair.
    @MainActor
    static func timestampFormatters(locale: Locale, timeZone: TimeZone) -> (day: DateFormatter, clock: DateFormatter) {
        let key = "\(locale.identifier)|\(timeZone.identifier)"
        if let cached = timestampFormatterCache[key] { return cached }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.dateStyle = .medium
        day.timeStyle = .none
        let clock = DateFormatter()
        clock.locale = locale
        clock.timeZone = timeZone
        clock.dateStyle = .none
        clock.timeStyle = .short
        timestampFormatterCache[key] = (day, clock)
        return (day, clock)
    }

    @MainActor
    private static var timestampFormatterCache: [String: (day: DateFormatter, clock: DateFormatter)] = [:]
}
