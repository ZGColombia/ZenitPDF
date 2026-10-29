import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// View ▸ Tint Markups by Author (NL-COLLAB-06): every markup's stroke in its author's colour, for
/// "who drew what". Display only — the stored style is untouched, so turning it off (or saving,
/// reopening, printing, exporting) shows the markups' own colours.
@MainActor
enum AuthorTint {

    static let noteID = UUID(uuidString: "5C0E9A44-1B7F-4D2A-8E36-0F9B2D71C8A5")!

    /// The shapes with each one's stroke replaced by its author's colour. Shapes with no author
    /// keep their own colour.
    static func apply(
        to shapes: [CanvasMarkupShape], records: [MarkupRecord], allAuthors: [String], aliases: Set<String> = []
    ) -> [CanvasMarkupShape] {
        apply(
            to: shapes,
            authorByID: authorsByID(records),
            colours: AuthorColors.assignments(for: allAuthors, aliases: aliases)
        )
    }

    /// Each record's author, by markup identity: the first record wins a duplicated identity.
    static func authorsByID(_ records: [MarkupRecord]) -> [UUID: String] {
        Dictionary(records.map { ($0.id.rawValue, $0.author) }, uniquingKeysWith: { first, _ in first })
    }

    /// The tint from inputs a caller computed once — the canvas keeps both across Select-drag
    /// frames, where neither can change (T-004).
    static func apply(
        to shapes: [CanvasMarkupShape], authorByID: [UUID: String], colours: [String: ZenitNamedPalette.Entry]
    ) -> [CanvasMarkupShape] {
        shapes.map { shape in
            guard let author = authorByID[shape.id], let entry = colours[author] else { return shape }
            var tinted = shape
            tinted.color = entry.color
            return tinted
        }
    }

    /// Turns the tint on or off and says who is which colour.
    static func toggle(document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        core.canvas.tintsByAuthor.toggle()
        guard core.canvas.tintsByAuthor else { return }
        let legend = AuthorColors.legend(AuthorColors.assignments(for: core.snapshot.markups.map(\.author), aliases: core.review.myNames))
        core.document.post(AppWarning(
            id: noteID,
            severity: .info,
            title: NSLocalizedString("Markups tinted by author", comment: "Author tint note title"),
            message: legend.isEmpty
                ? NSLocalizedString("No markup names an author.", comment: "Author tint note when nobody signed anything")
                : legend,
            source: NSLocalizedString("Review", comment: "Status note source for review imports"),
            isDismissible: true,
            timestamp: Date()
        ))
    }
}
