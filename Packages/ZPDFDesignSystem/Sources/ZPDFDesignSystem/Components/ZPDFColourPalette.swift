import AppKit
import Observation
import SwiftUI
import ZPDFUIPresentation

// The colour palette a swatch opens (NL-MARKUP-01, the fix for LT3-01).
//
// Before this file the Inspector's swatches were a painted square over a system colour well
// drawn at 2 % opacity. In a binary stamped with the macOS 14 SDK — which the shipped app is —
// SwiftUI leaves a hosted AppKit control that faint out of hit-testing, so the click fell
// through and nothing happened. The palette replaces the trick with ordinary buttons: a swatch
// is a real `Button`, it opens this grid in a popover, and "More Colours…" drives
// `NSColorPanel` directly through an explicit target and action (`ZPDFColourPanelController`).

// MARK: - Markup inks

/// The markup inks the palette offers, in palette order.
///
/// They are drawn on paper, so like the ink tokens they keep one value in every appearance.
/// Every ink holds at least 4.5:1 against the white sheet: the stroke colour of a text box is
/// also its text colour, so the text threshold applies, not only the 3:1 of a graphic.
/// `ZPDFSelfCheck` asserts both the ratio and that the first three are the ink tokens.
public enum ZPDFMarkupInk: String, CaseIterable, Sendable, Hashable, Identifiable {
    // Twelve construction-legible inks (NL-MARKUP-14, round 2 added navy and olive).
    case blue, red, green, orange, purple, magenta, teal, brown, grey, black, navy, olive

    public var id: String { rawValue }

    /// The spoken and tooltip name. A swatch is never identified by its colour alone.
    public var displayName: String {
        switch self {
        case .blue: return NSLocalizedString("Blue", comment: "Markup ink name in the colour palette")
        case .red: return NSLocalizedString("Red", comment: "Markup ink name in the colour palette")
        case .green: return NSLocalizedString("Green", comment: "Markup ink name in the colour palette")
        case .orange: return NSLocalizedString("Orange", comment: "Markup ink name in the colour palette")
        case .purple: return NSLocalizedString("Purple", comment: "Markup ink name in the colour palette")
        case .magenta: return NSLocalizedString("Magenta", comment: "Markup ink name in the colour palette")
        case .teal: return NSLocalizedString("Teal", comment: "Markup ink name in the colour palette")
        case .brown: return NSLocalizedString("Brown", comment: "Markup ink name in the colour palette")
        case .grey: return NSLocalizedString("Grey", comment: "Markup ink name in the colour palette")
        case .black: return NSLocalizedString("Black", comment: "Markup ink name in the colour palette")
        case .navy: return NSLocalizedString("Navy", comment: "Markup ink name in the colour palette")
        case .olive: return NSLocalizedString("Olive", comment: "Markup ink name in the colour palette")
        }
    }

    /// The ink's value. Blue, red and green are the design-system ink tokens themselves.
    public var rgba: ZPDFRGBA {
        switch self {
        case .blue: return ZPDFColor.rgba(.inkBlue, .dark)
        case .red: return ZPDFColor.rgba(.inkRed, .dark)
        case .green: return ZPDFColor.rgba(.inkGreen, .dark)
        case .orange: return ZPDFRGBA(hex: 0xB85A0B)
        case .purple: return ZPDFRGBA(hex: 0x6A3DB5)
        case .magenta: return ZPDFRGBA(hex: 0xB0246F)
        case .teal: return ZPDFRGBA(hex: 0x0B727C)
        case .brown: return ZPDFRGBA(hex: 0x7A4A1C)
        case .grey: return ZPDFRGBA(hex: 0x5E6875)
        case .black: return ZPDFRGBA(hex: 0x1C2026)
        case .navy: return ZPDFRGBA(hex: 0x1F2F6B)
        case .olive: return ZPDFRGBA(hex: 0x5A6014)
        }
    }

    /// The ink as the presentation colour a style edit carries.
    public var color: ColorRGBA { rgba.presentationColor }

    /// The ink whose value this colour is, ignoring alpha — how a fill at 20 % still reads as
    /// "Blue" in the palette.
    public static func matching(_ color: ColorRGBA?) -> ZPDFMarkupInk? {
        guard let color else { return nil }
        return allCases.first { ZPDFColourMath.sameHue($0.color, color) }
    }
}

/// Colour comparisons the palette and the recent-colours row share.
public enum ZPDFColourMath {

    /// Whether two colours have the same red, green and blue to 8 bits, whatever their alpha.
    ///
    /// 8 bits because that is what a colour survives as through `NSColor` and a hex code; an
    /// exact `Double` comparison called a round-tripped ink a different colour.
    public static func sameHue(_ a: ColorRGBA, _ b: ColorRGBA) -> Bool {
        quantised(a.red) == quantised(b.red)
            && quantised(a.green) == quantised(b.green)
            && quantised(a.blue) == quantised(b.blue)
    }

    /// The colour made opaque, which is how a pick is recorded and offered again.
    public static func opaque(_ color: ColorRGBA) -> ColorRGBA {
        ColorRGBA(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func quantised(_ component: Double) -> Int {
        guard component.isFinite else { return 0 }
        return Int((min(1, max(0, component)) * 255).rounded())
    }
}

// MARK: - Recent colours

/// The colours most recently applied from a palette or the colour panel, newest first.
///
/// Storage is injected. The shell gives the assembled application `UserDefaults.standard`, and
/// everything else — `swift test`, a probe, a preview — an in-memory store, so no test run can
/// leave a recent colour behind for the next one (the test-tier hygiene rule).
@MainActor
@Observable
public final class ZPDFRecentColours {

    /// How many colours the row keeps.
    public static let capacity = 8

    /// Newest first, opaque, no duplicates.
    public private(set) var colours: [ColorRGBA]

    @ObservationIgnored private let save: ((Data) -> Void)?

    /// Creates a store over explicit storage: `load` answers what was saved last, `save` keeps
    /// the new list. With neither, the list lives only as long as this object.
    public init(load: (() -> Data?)? = nil, save: ((Data) -> Void)? = nil) {
        self.save = save
        if let data = load?(), let stored = try? JSONDecoder().decode([ColorRGBA].self, from: data) {
            colours = Array(stored.prefix(Self.capacity))
        } else {
            colours = []
        }
    }

    /// Creates a store kept in `defaults` under `key`, or in memory when `defaults` is nil.
    public convenience init(defaults: UserDefaults?, key: String = "Zenit.ColourPalette.Recent") {
        guard let defaults else {
            self.init()
            return
        }
        self.init(load: { defaults.data(forKey: key) }, save: { defaults.set($0, forKey: key) })
    }

    /// Records an applied colour at the front, dropping an older copy of the same hue.
    public func record(_ color: ColorRGBA) {
        let opaque = ZPDFColourMath.opaque(color)
        guard opaque.red.isFinite, opaque.green.isFinite, opaque.blue.isFinite else { return }
        var next = colours.filter { !ZPDFColourMath.sameHue($0, opaque) }
        next.insert(opaque, at: 0)
        colours = Array(next.prefix(Self.capacity))
        if let save, let data = try? JSONEncoder().encode(colours) {
            save(data)
        }
    }
}

// MARK: - Company colours (NL-MARKUP-14)

/// A company's own standard colours, kept by the person and offered in every palette: the
/// "revisions are this red" list. Up to twelve, in the order they were added.
///
/// Storage is injected on the same terms as ``ZPDFRecentColours``: the assembled application
/// passes `UserDefaults.standard`, everything else keeps the list in memory.
@MainActor
@Observable
public final class ZPDFCompanyColours {

    /// How many colours the company row keeps.
    public static let capacity = 12

    /// In the order they were added, opaque, no duplicates.
    public private(set) var colours: [ColorRGBA]

    @ObservationIgnored private let save: ((Data) -> Void)?

    public init(load: (() -> Data?)? = nil, save: ((Data) -> Void)? = nil) {
        self.save = save
        if let data = load?(), let stored = try? JSONDecoder().decode([ColorRGBA].self, from: data) {
            colours = Array(stored.prefix(Self.capacity))
        } else {
            colours = []
        }
    }

    public convenience init(defaults: UserDefaults?, key: String = "Zenit.ColourPalette.Company") {
        guard let defaults else {
            self.init()
            return
        }
        self.init(load: { defaults.data(forKey: key) }, save: { defaults.set($0, forKey: key) })
    }

    /// Adds a colour at the end; a hue already present, or a full list, changes nothing.
    /// Returns whether it was added.
    @discardableResult
    public func add(_ color: ColorRGBA) -> Bool {
        let opaque = ZPDFColourMath.opaque(color)
        guard opaque.red.isFinite, opaque.green.isFinite, opaque.blue.isFinite,
              colours.count < Self.capacity,
              !colours.contains(where: { ZPDFColourMath.sameHue($0, opaque) }) else { return false }
        colours.append(opaque)
        persist()
        return true
    }

    /// Removes a colour by hue.
    public func remove(_ color: ColorRGBA) {
        colours.removeAll { ZPDFColourMath.sameHue($0, color) }
        persist()
    }

    private func persist() {
        if let save, let data = try? JSONEncoder().encode(colours) { save(data) }
    }
}

// MARK: - Eyedropper (NL-MARKUP-14)

/// Picks a colour from anywhere on screen. The product's is `NSColorSampler` — sandbox-safe,
/// no screen-recording permission — and a test injects a sampler that answers at once, so no
/// loupe ever appears during a test run.
@MainActor
public protocol ZPDFColourSampling: AnyObject {
    /// Shows the sampler and answers the picked colour, or `nil` when the person cancelled.
    func sample(_ completion: @escaping @MainActor (ColorRGBA?) -> Void)
}

/// The system eyedropper.
@MainActor
public final class ZPDFSystemColourSampler: ZPDFColourSampling {
    public init() {}
    public func sample(_ completion: @escaping @MainActor (ColorRGBA?) -> Void) {
        NSColorSampler().show { picked in
            let colour = picked.flatMap { $0.usingColorSpace(.sRGB) }.map {
                ColorRGBA(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent), alpha: 1)
            }
            MainActor.assumeIsolated { completion(colour) }
        }
    }
}

// MARK: - Palette view

/// The palette grid: the markup inks, the recent colours, an optional "No Fill" and
/// "More Colours…".
///
/// Every cell is a plain SwiftUI `Button` drawn at full opacity — nothing here is hosted
/// AppKit, and nothing is transparent, so it is clickable in every SDK's hit-testing.
public struct ZPDFColourPalette: View {

    /// What the palette shows.
    public struct Content: Equatable {
        /// The palette's heading, e.g. "Border colour".
        public var title: String
        /// The colour the selection has now, or `nil` when mixed or unset.
        public var current: ColorRGBA?
        /// The recent colours, newest first.
        public var recents: [ColorRGBA]
        /// The title of the "no colour" choice ("No Fill"), or `nil` to leave it out.
        public var noneTitle: String?
        /// The company's own colours (NL-MARKUP-14), in the order they were added.
        public var company: [ColorRGBA] = []
        /// The colours already used on this project's markups, most used first.
        public var project: [ColorRGBA] = []

        public init(
            title: String,
            current: ColorRGBA?,
            recents: [ColorRGBA],
            noneTitle: String? = nil,
            company: [ColorRGBA] = [],
            project: [ColorRGBA] = []
        ) {
            self.title = title
            self.current = current
            self.recents = recents
            self.noneTitle = noneTitle
            self.company = company
            self.project = project
        }
    }

    /// Columns in the ink grid.
    public static let columns = 5
    /// One cell's side. The 24 pt minimum hit target, so a cell is no smaller to hit than any
    /// other control in the product.
    public static let cell: CGFloat = ZPDFSpacing.Control.minimumHitTarget
    /// Space between cells.
    public static let gap: CGFloat = ZPDFSpacing.s

    private let content: Content
    private let onPick: (ColorRGBA) -> Void
    private let onNone: (() -> Void)?
    private let onMore: () -> Void
    private let onSample: (() -> Void)?
    private let onAddToCompany: (() -> Void)?
    private let onRemoveFromCompany: ((ColorRGBA) -> Void)?

    /// - Parameter onRemoveFromCompany: takes a colour out of the company row, answered with the
    ///   stored company colour. With it, every company swatch has a "Remove from Company Colours"
    ///   context menu, and the Add row becomes a Remove row when the current colour is already a
    ///   company colour (U-042).
    public init(
        content: Content,
        onPick: @escaping (ColorRGBA) -> Void,
        onNone: (() -> Void)? = nil,
        onMore: @escaping () -> Void,
        onSample: (() -> Void)? = nil,
        onAddToCompany: (() -> Void)? = nil,
        onRemoveFromCompany: ((ColorRGBA) -> Void)? = nil
    ) {
        self.content = content
        self.onPick = onPick
        self.onNone = onNone
        self.onMore = onMore
        self.onSample = onSample
        self.onAddToCompany = onAddToCompany
        self.onRemoveFromCompany = onRemoveFromCompany
    }

    /// What the palette offers for the current colour and the company row (U-042).
    public enum CompanyOffer: Equatable, Sendable {
        /// Nothing: no current colour (a mixed or unset selection).
        case nothing
        /// "Add to Company Colours": the colour is new and the row has room.
        case add
        /// The colour is already a company colour, by hue; carries the stored one. Adding it
        /// again would change nothing, so the palette offers to take it out instead.
        case remove(ColorRGBA)
        /// The row holds ``ZPDFCompanyColours/capacity`` colours: Add is shown off, with the reason.
        case full
    }

    /// The one rule for the company row's action. The Add row used to show for any current
    /// colour, and `ZPDFCompanyColours.add` refused a duplicate or a thirteenth colour without a
    /// word, so the button did nothing (U-042).
    public static func companyOffer(current: ColorRGBA?, company: [ColorRGBA]) -> CompanyOffer {
        guard let current else { return .nothing }
        if let stored = company.first(where: { ZPDFColourMath.sameHue($0, current) }) { return .remove(stored) }
        return company.count >= ZPDFCompanyColours.capacity ? .full : .add
    }

    /// The help text of the Add row when the company row is full.
    public static var companyFullHelp: String {
        String(
            format: NSLocalizedString(
                "Company Colours holds %lld colours. Remove one to add another.",
                comment: "Colour palette: help of the disabled Add to Company Colours row; the capacity"
            ),
            ZPDFCompanyColours.capacity
        )
    }

    /// The title of the action that takes a colour out of the company row.
    public static var removeFromCompanyTitle: String {
        NSLocalizedString("Remove from Company Colours", comment: "Colour palette: take a colour out of the company row")
    }

    /// The identifier a swatch cell's marker view carries, so an off-screen probe can find the
    /// cell without an accessibility client attached.
    public static func markerIdentifier(for ink: ZPDFMarkupInk) -> String { "zpdf.palette.ink.\(ink.rawValue)" }
    public static let moreMarkerIdentifier = "zpdf.palette.more"
    public static let noneMarkerIdentifier = "zpdf.palette.none"
    public static func recentMarkerIdentifier(index: Int) -> String { "zpdf.palette.recent.\(index)" }
    public static func companyMarkerIdentifier(index: Int) -> String { "zpdf.palette.company.\(index)" }
    public static func projectMarkerIdentifier(index: Int) -> String { "zpdf.palette.project.\(index)" }
    public static let sampleMarkerIdentifier = "zpdf.palette.sample"
    public static let addCompanyMarkerIdentifier = "zpdf.palette.add-company"
    public static let removeCompanyMarkerIdentifier = "zpdf.palette.remove-company"

    /// How many project colours the row shows.
    public static let projectCapacity = 8

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(content.title)
                .zpdfText(.caption, .textSecondary)
                .accessibilityAddTraits(.isHeader)
            grid(ZPDFMarkupInk.allCases.map { ink in
                Cell(
                    color: ink.color,
                    name: ink.displayName,
                    isSelected: content.current.map { ZPDFColourMath.sameHue($0, ink.color) } ?? false,
                    marker: Self.markerIdentifier(for: ink)
                )
            })
            if !content.recents.isEmpty {
                Text(NSLocalizedString("Recent", comment: "Colour palette: heading of the recent colours row"))
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityAddTraits(.isHeader)
                grid(content.recents.prefix(ZPDFRecentColours.capacity).enumerated().map { index, colour in
                    Cell(
                        color: colour,
                        name: String(
                            format: NSLocalizedString(
                                "Recent colour %@", comment: "Colour palette: a recent colour, named by its hex code"
                            ),
                            colour.hexString
                        ),
                        isSelected: content.current.map { ZPDFColourMath.sameHue($0, colour) } ?? false,
                        marker: Self.recentMarkerIdentifier(index: index)
                    )
                })
            }
            swatchRow(
                NSLocalizedString("Company", comment: "Colour palette: heading of the company colours row"),
                colours: Array(content.company.prefix(ZPDFCompanyColours.capacity)),
                name: NSLocalizedString("Company colour %@", comment: "Colour palette: a company colour, named by its hex code"),
                marker: Self.companyMarkerIdentifier(index:),
                onRemove: onRemoveFromCompany
            )
            swatchRow(
                NSLocalizedString("In This Project", comment: "Colour palette: heading of the row of colours already used in the project"),
                colours: Array(content.project.prefix(Self.projectCapacity)),
                name: NSLocalizedString("Project colour %@", comment: "Colour palette: a colour used in the project, named by its hex code"),
                marker: Self.projectMarkerIdentifier(index:)
            )
            ZPDFHairlineDivider()
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                if let onSample {
                    rowButton(
                        NSLocalizedString("Pick from Drawing", comment: "Colour palette: the eyedropper"),
                        marker: Self.sampleMarkerIdentifier,
                        action: onSample
                    ) {
                        Image(systemName: "eyedropper").foregroundStyle(ZPDFColor.textSecondary)
                    }
                }
                companyRow
                if let noneTitle = content.noneTitle, let onNone {
                    rowButton(noneTitle, marker: Self.noneMarkerIdentifier, action: onNone) {
                        ZPDFNoColourGlyph()
                    }
                }
                rowButton(
                    NSLocalizedString("More Colours…", comment: "Colour palette: opens the system colour panel"),
                    marker: Self.moreMarkerIdentifier,
                    action: onMore
                ) {
                    ZPDFGlyphView(.symbol(.more), size: ZPDFSpacing.Control.iconSmall)
                        .foregroundStyle(ZPDFColor.textSecondary)
                }
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(content.title))
    }

    /// The company row's action for the current colour (U-042): Add when it is new, Remove when it
    /// is already there, and Add shown off with its reason when the row is full.
    @ViewBuilder
    private var companyRow: some View {
        switch Self.companyOffer(current: content.current, company: content.company) {
        case .nothing:
            EmptyView()
        case .add:
            if let onAddToCompany { addToCompanyRow(onAddToCompany) }
        case .full:
            if let onAddToCompany {
                addToCompanyRow(onAddToCompany)
                    .disabled(true)
                    .help(Self.companyFullHelp)
                    .accessibilityHint(Text(Self.companyFullHelp))
            }
        case .remove(let stored):
            if let onRemoveFromCompany {
                rowButton(
                    Self.removeFromCompanyTitle,
                    marker: Self.removeCompanyMarkerIdentifier,
                    action: { onRemoveFromCompany(stored) }
                ) {
                    Image(systemName: "minus.square").foregroundStyle(ZPDFColor.textSecondary)
                }
            }
        }
    }

    private func addToCompanyRow(_ action: @escaping () -> Void) -> some View {
        rowButton(
            NSLocalizedString("Add to Company Colours", comment: "Colour palette: keep the current colour in the company row"),
            marker: Self.addCompanyMarkerIdentifier,
            action: action
        ) {
            Image(systemName: "plus.square").foregroundStyle(ZPDFColor.textSecondary)
        }
    }

    @ViewBuilder
    private func swatchRow(
        _ heading: String,
        colours: [ColorRGBA],
        name: String,
        marker: @escaping (Int) -> String,
        onRemove: ((ColorRGBA) -> Void)? = nil
    ) -> some View {
        if !colours.isEmpty {
            Text(heading)
                .zpdfText(.caption, .textSecondary)
                .accessibilityAddTraits(.isHeader)
            grid(colours.enumerated().map { index, colour in
                Cell(
                    color: colour,
                    name: String(format: name, colour.hexString),
                    isSelected: content.current.map { ZPDFColourMath.sameHue($0, colour) } ?? false,
                    marker: marker(index)
                )
            }, onRemove: onRemove)
        }
    }

    /// The colours a project's markups use, most used first, opaque, one per hue — the palette's
    /// "In This Project" row.
    public static func projectColours(from strokes: [ColorRGBA]) -> [ColorRGBA] {
        var counts: [(ColorRGBA, Int)] = []
        for stroke in strokes {
            let opaque = ZPDFColourMath.opaque(stroke)
            if let index = counts.firstIndex(where: { ZPDFColourMath.sameHue($0.0, opaque) }) {
                counts[index].1 += 1
            } else {
                counts.append((opaque, 1))
            }
        }
        // Stable: equal counts keep first-seen order.
        return counts.enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
            .prefix(projectCapacity)
            .map { $0 }
    }

    /// The palette's width: the grid plus its padding.
    public static var width: CGFloat {
        CGFloat(columns) * cell + CGFloat(columns - 1) * gap + 2 * ZPDFSpacing.l
    }

    private struct Cell: Identifiable {
        let color: ColorRGBA
        let name: String
        let isSelected: Bool
        let marker: String
        var id: String { marker }
    }

    private func grid(_ cells: [Cell], onRemove: ((ColorRGBA) -> Void)? = nil) -> some View {
        let rows = stride(from: 0, to: cells.count, by: Self.columns).map { Array(cells[$0..<min($0 + Self.columns, cells.count)]) }
        return VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(rows[row]) { cell in
                        ZPDFPaletteSwatch(color: cell.color, name: cell.name, isSelected: cell.isSelected) {
                            onPick(cell.color)
                        }
                        .modifier(ZPDFRemovableSwatch(colour: cell.color, onRemove: onRemove))
                        .zpdfMarker(cell.marker)
                    }
                }
            }
        }
    }


    private func rowButton<Icon: View>(
        _ title: String,
        marker: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ZPDFSpacing.m) {
                icon().frame(width: ZPDFSpacing.Control.icon, height: ZPDFSpacing.Control.icon)
                Text(title).zpdfText(.control, .textPrimary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: ZPDFSpacing.Control.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zpdfMarker(marker)
        .accessibilityLabel(Text(title))
    }
}

/// A company swatch's "Remove from Company Colours", as a context menu and as a named
/// accessibility action; nothing on any other swatch (U-042).
private struct ZPDFRemovableSwatch: ViewModifier {
    let colour: ColorRGBA
    let onRemove: ((ColorRGBA) -> Void)?

    func body(content: Content) -> some View {
        if let onRemove {
            content
                .contextMenu {
                    Button(ZPDFColourPalette.removeFromCompanyTitle) { onRemove(colour) }
                }
                .accessibilityAction(named: Text(ZPDFColourPalette.removeFromCompanyTitle)) { onRemove(colour) }
        } else {
            content
        }
    }
}

/// One palette cell: a colour square with a name, and a ring — a shape, not only a colour —
/// when it is the current colour.
public struct ZPDFPaletteSwatch: View {

    let color: ColorRGBA
    let name: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    public init(color: ColorRGBA, name: String, isSelected: Bool, action: @escaping () -> Void) {
        self.color = color
        self.name = name
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
        Button(action: action) {
            shape
                .fill(ZPDFColourMath.opaque(color).swiftUIColor)
                .overlay {
                    shape.strokeBorder(
                        ZPDFColor.color(isHovering ? .accentBlue : .borderStrong),
                        lineWidth: ZPDFStroke.regular
                    )
                }
                .padding(isSelected ? 3 : 0)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                            .strokeBorder(ZPDFColor.accentBlue, lineWidth: ZPDFStroke.focusRing)
                    }
                }
                .frame(width: ZPDFColourPalette.cell, height: ZPDFColourPalette.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(name)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The "no colour" glyph: an empty square with a diagonal, the same drawing the Inspector
/// swatch uses for a mixed or unset colour.
struct ZPDFNoColourGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
                    .strokeBorder(ZPDFColor.color(.borderStrong), lineWidth: ZPDFStroke.regular)
                Path { path in
                    path.move(to: CGPoint(x: side - 3, y: 3))
                    path.addLine(to: CGPoint(x: 3, y: side - 3))
                }
                .stroke(ZPDFColor.danger, lineWidth: ZPDFStroke.regular)
            }
        }
        .accessibilityHidden(true)
    }
}
