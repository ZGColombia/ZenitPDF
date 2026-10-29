import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Model

/// One bookmark of the drawing's own outline, resolved to a page of the set.
public struct NavigatorBookmark: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// The page it points at, or `nil` when the destination names no page of this drawing.
    public let pageID: PageDescriptor.ID?
    public let children: [NavigatorBookmark]
    /// Where on the page it lands, in page space; each `nil` when the bookmark leaves that axis
    /// to the reader (NL-DOCS-06, BH-586 semantics).
    public let left: Double?
    public let top: Double?

    public init(
        id: String, title: String, pageID: PageDescriptor.ID?, children: [NavigatorBookmark] = [],
        left: Double? = nil, top: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.pageID = pageID
        self.children = children
        self.left = left
        self.top = top
    }
}

/// The Pages tab's two views (NL-DOCS-06): the mockup's cards, or a dense index of sheets.
enum NavigatorPagesMode: String, CaseIterable, Identifiable {
    case cards
    case index

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return NSLocalizedString("Cards", comment: "Pages tab view: page cards with thumbnails")
        case .index: return NSLocalizedString("Index", comment: "Pages tab view: a dense list of sheets by discipline")
        }
    }
}

/// The sheet index, as values: rows grouped by discipline, filtered by a typed query.
enum NavigatorSheetIndex {

    struct Row: Identifiable, Equatable {
        let id: PageDescriptor.ID
        /// "A-101", the page label when it is a name, else the position.
        let number: String
        /// "FLOOR PLAN LEVEL 1", or empty.
        let title: String
        let position: Int
    }

    struct Group: Identifiable, Equatable {
        /// "A", "S", or "" for sheets without a discipline prefix.
        let id: String
        let rows: [Row]
    }

    /// The row for one page: its sheet number and title when the set named it, else its label
    /// (when a name) and outline-or-label title, else its position.
    static func row(for page: PageDescriptor, position: Int) -> Row {
        if let (number, title) = NavigatorSheetNameEditor.splitSheetIdentity(page) {
            return Row(id: page.id, number: number.isEmpty ? (position + 1).formatted() : number, title: title, position: position)
        }
        let label = page.label.trimmingCharacters(in: .whitespaces)
        let isName = !label.isEmpty && !label.allSatisfy(\.isNumber)
        let title = (page.sheetTitle ?? "") == label ? "" : (page.sheetTitle ?? "")
        return Row(id: page.id, number: isName ? label : (position + 1).formatted(), title: title, position: position)
    }

    /// The discipline of a row: the letters its number starts with.
    static func discipline(of row: Row) -> String {
        let prefix = row.number.prefix { $0.isLetter }
        return String(prefix).uppercased()
    }

    /// Rows grouped by discipline, groups in the order their first sheet appears in the set.
    static func groups(pages: [PageDescriptor], query: String = "") -> [Group] {
        let rows = pages.enumerated().map { row(for: $1, position: $0) }.filter { matches($0, query: query) }
        var order: [String] = []
        var byDiscipline: [String: [Row]] = [:]
        for row in rows {
            let key = discipline(of: row)
            if byDiscipline[key] == nil { order.append(key) }
            byDiscipline[key, default: []].append(row)
        }
        return order.map { Group(id: $0, rows: byDiscipline[$0] ?? []) }
    }

    /// Whether a row matches a typed query: its number with separators ignored ("A5" finds
    /// A-501), or any word of its title.
    static func matches(_ row: Row, query: String) -> Bool {
        let wanted = compact(query)
        guard !wanted.isEmpty else { return true }
        if compact(row.number).hasPrefix(wanted) { return true }
        return row.title.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }

    /// The first sheet a query selects, in set order.
    static func firstMatch(pages: [PageDescriptor], query: String) -> PageDescriptor.ID? {
        guard !compact(query).isEmpty else { return nil }
        for (position, page) in pages.enumerated() where matches(row(for: page, position: position), query: query) {
            return page.id
        }
        return nil
    }

    private static func compact(_ text: String) -> String {
        String(text.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

// MARK: - Views

/// The index view: a filter field, then sheets grouped by discipline, then the drawing's own
/// bookmarks under a disclosure. Typing selects the first matching sheet.
struct NavigatorSheetIndexView: View {

    let environment: ProjectShellEnvironment

    @State private var query = ""
    @State private var showsBookmarks = true

    var body: some View {
        let pages = environment.document.pages
        let current = environment.document.currentPageID
        VStack(spacing: 0) {
            TextField(Self.filterPlaceholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, ZPDFSpacing.s)
                .padding(.vertical, ZPDFSpacing.xs)
                .accessibilityLabel(Text(Self.filterPlaceholder))
                .onChange(of: query) { _, typed in
                    if let hit = NavigatorSheetIndex.firstMatch(pages: pages, query: typed) {
                        environment.selectPage(id: hit, mode: .replace)
                    }
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(NavigatorSheetIndex.groups(pages: pages, query: query)) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    NavigatorSheetIndexRow(row: row, isCurrent: row.id == current) {
                                        environment.selectPage(id: row.id, mode: .replace)
                                    }
                                    .id(row.id)
                                }
                            } header: {
                                Text(group.id.isEmpty ? Self.otherSheets : group.id)
                                    .zpdfText(.rowLabel.withWeight(.semibold), .textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, ZPDFSpacing.m)
                                    .padding(.vertical, ZPDFSpacing.xs)
                                    .background(ZPDFColor.color(NavigatorStyle.panelFill))
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                        if !environment.navigatorBookmarks.isEmpty {
                            DisclosureGroup(isExpanded: $showsBookmarks) {
                                NavigatorBookmarkList(bookmarks: environment.navigatorBookmarks) { bookmark in
                                    guard let pageID = bookmark.pageID else { return }
                                    // Lands where the bookmark points, and ⌘[ comes back (NL-DOCS-06/09).
                                    if let open = environment.onOpenBookmark {
                                        open(bookmark)
                                    } else {
                                        environment.selectPage(id: pageID, mode: .replace)
                                    }
                                }
                            } label: {
                                Text(Self.bookmarksTitle)
                                    .zpdfText(.rowLabel.withWeight(.semibold), .textSecondary)
                            }
                            .padding(.horizontal, ZPDFSpacing.m)
                            .padding(.top, ZPDFSpacing.s)
                        }
                    }
                    .padding(.bottom, ZPDFSpacing.s)
                }
                .onChange(of: current) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NavigatorPagesMode.index.title))
    }

    static var filterPlaceholder: String {
        NSLocalizedString("Filter sheets", comment: "Pages index: the filter field's placeholder")
    }
    static var bookmarksTitle: String {
        NSLocalizedString("Bookmarks", comment: "Pages index: the drawing's own bookmarks")
    }
    static var otherSheets: String {
        NSLocalizedString("Other Sheets", comment: "Pages index: sheets whose number has no discipline letter")
    }
}

private struct NavigatorSheetIndexRow: View {
    let row: NavigatorSheetIndex.Row
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZPDFSpacing.s) {
                Text(row.number)
                    .zpdfText(.monoNumeric.withSize(12), .textPrimary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)
                Text(row.title)
                    .zpdfText(.rowLabel, .textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.m)
            .frame(height: 24)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: ZPDFRadius.label).fill(ZPDFColor.color(NavigatorStyle.accent).opacity(NavigatorStyle.selectionTint))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: ZPDFRadius.label).fill(ZPDFColor.color(NavigatorStyle.hover))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(row.title.isEmpty ? row.number : "\(row.number), \(row.title)"))
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }
}

private struct NavigatorBookmarkList: View {
    let bookmarks: [NavigatorBookmark]
    let open: (NavigatorBookmark) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bookmarks) { bookmark in
                if bookmark.children.isEmpty {
                    item(bookmark)
                } else {
                    DisclosureGroup {
                        NavigatorBookmarkList(bookmarks: bookmark.children, open: open)
                            .padding(.leading, ZPDFSpacing.s)
                    } label: {
                        item(bookmark)
                    }
                }
            }
        }
    }

    private func item(_ bookmark: NavigatorBookmark) -> some View {
        Button {
            if bookmark.pageID != nil { open(bookmark) }
        } label: {
            Text(bookmark.title)
                .zpdfText(.rowLabel, bookmark.pageID == nil ? .textTertiary : .textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bookmark.pageID == nil)
        .help(bookmark.title)
    }
}
