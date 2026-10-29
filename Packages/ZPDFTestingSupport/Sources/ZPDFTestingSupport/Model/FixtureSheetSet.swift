import Foundation

/// One sheet of a set: its number, its title and the discipline its number starts with.
public struct FixtureSheet: Sendable, Codable, Hashable {
    public var pageIndex: Int
    /// "A-101".
    public var number: String
    /// "FLOOR PLAN LEVEL 1".
    public var title: String
    /// "A", "S", "M".
    public var discipline: String

    public init(pageIndex: Int, number: String, title: String, discipline: String) {
        self.pageIndex = pageIndex
        self.number = number
        self.title = title
        self.discipline = discipline
    }
}

/// One bookmark, with its children, as written into `/Outlines`.
public struct FixtureOutlineEntry: Sendable, Codable, Hashable {
    public var title: String
    public var pageIndex: Int
    public var children: [FixtureOutlineEntry]

    public init(title: String, pageIndex: Int, children: [FixtureOutlineEntry] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

/// Where a link annotation goes.
public enum FixtureLinkTarget: Sendable, Codable, Hashable {
    /// `/A << /S /GoTo /D [page /XYZ left top null] >>` — an explicit page destination.
    case page(index: Int, left: Double?, top: Double?)
    /// `/Dest /name`, resolved through the catalog's `/Dests`.
    case named(String)
    /// `/A << /S /URI >>` — shown, never opened without asking.
    case uri(String)
    /// `/A << /S /JavaScript >>` — shown, never run.
    case javaScript(String)
}

/// One `/Link` annotation.
public struct FixtureLink: Sendable, Codable, Hashable {
    public var pageIndex: Int
    public var rect: FixtureRect
    public var target: FixtureLinkTarget

    public init(pageIndex: Int, rect: FixtureRect, target: FixtureLinkTarget) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.target = target
    }
}

/// A textual reference on a sheet to another sheet ("3/A-105", "SEE S-201").
public struct FixtureSheetReference: Sendable, Codable, Hashable {
    public var pageIndex: Int
    /// The text as printed.
    public var text: String
    /// The sheet number cited.
    public var citedSheet: String
    /// Whether a sheet with that number exists in the set.
    public var resolves: Bool

    public init(pageIndex: Int, text: String, citedSheet: String, resolves: Bool) {
        self.pageIndex = pageIndex
        self.text = text
        self.citedSheet = citedSheet
        self.resolves = resolves
    }
}

/// The document-structure truth of a sheet-set fixture: labels, bookmarks, named destinations,
/// links, the textual cross-references, and the title-block regions a sheet-naming feature
/// reads from.
public struct FixtureSheetSet: Sendable, Codable, Hashable {
    public var sheets: [FixtureSheet]
    /// The `/PageLabels` every page must resolve to, in page order.
    public var pageLabels: [String]
    public var outline: [FixtureOutlineEntry]
    /// Named destinations in the catalog's `/Dests`, name → page index.
    public var namedDestinations: [String: Int]
    public var links: [FixtureLink]
    public var references: [FixtureSheetReference]
    /// The box around the sheet number in each title block, in page space.
    public var numberRegion: FixtureRect
    /// The box around the sheet title in each title block, in page space.
    public var titleRegion: FixtureRect

    public init(
        sheets: [FixtureSheet],
        pageLabels: [String],
        outline: [FixtureOutlineEntry],
        namedDestinations: [String: Int],
        links: [FixtureLink],
        references: [FixtureSheetReference],
        numberRegion: FixtureRect,
        titleRegion: FixtureRect
    ) {
        self.sheets = sheets
        self.pageLabels = pageLabels
        self.outline = outline
        self.namedDestinations = namedDestinations
        self.links = links
        self.references = references
        self.numberRegion = numberRegion
        self.titleRegion = titleRegion
    }
}
