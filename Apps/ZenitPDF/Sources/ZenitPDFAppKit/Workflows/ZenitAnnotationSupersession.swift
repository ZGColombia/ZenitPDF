import Foundation

/// Which of Zenit's own annotations in a drawing an output leaves out (L-23).
///
/// After Save Markups into PDF the drawing carries one annotation per markup, its `/NM` the
/// markup's id. An output that paints the project's markups (Print, Marked, the layered export)
/// or promises none (Clean) must not draw those pictures as well, or each markup appears twice.
/// It must also not drop an annotation the canvas still shows: a colleague saved markups into
/// the PDF, and this project — not restored, or with markups of its own — does not hold them.
///
/// So an output leaves out exactly the annotations the canvas does not show as annotations:
///
/// - every markup in the session, painted or not (a hidden markup, a layer kept off paper), so a
///   markup that is not painted is not drawn from its old annotation either;
/// - every annotation the canvas hid when a takeoff was restored from the file
///   (``EmbeddedTakeoffRestore/hideOwnAnnotations(of:restoredIDs:)``), still hidden after its
///   markup is deleted;
/// - every annotation this window wrote into its own drawing (Save Markups into PDF in place),
///   which the canvas, still drawing the file as it opened, never shows.
///
/// The bridge's and the exporter's rule then adds the first export's unnamed `/Subj (Zenit)`
/// marks, which name no markup.
@MainActor
enum ZenitAnnotationSupersession {

    /// The names recorded per open document, released with it.
    private static let recorded = NSMapTable<ZenitPDFProjectDocument, NSMutableSet>.weakToStrongObjects()

    /// Remembers `names` (`/NM` texts) as annotations the canvas does not show for `document`.
    static func record(_ names: some Sequence<String>, for document: ZenitPDFProjectDocument) {
        let set = recorded.object(forKey: document) ?? {
            let created = NSMutableSet()
            recorded.setObject(created, forKey: document)
            return created
        }()
        for name in names { set.add(name as NSString) }
    }

    /// The `/NM` names whose Zenit annotation every output of `document` leaves out.
    static func names(for document: ZenitPDFProjectDocument) async -> Set<String> {
        var names = Set((recorded.object(forKey: document)?.allObjects ?? []).compactMap { $0 as? String })
        if let session = document.core?.session {
            for record in await session.drawOrderedMarkups {
                names.insert(record.id.rawValue.uuidString)
            }
        }
        return names
    }
}
