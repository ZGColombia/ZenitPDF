import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// The application side of the round-2 markup verbs (r2-markup): group and ungroup
/// (NL-MARKUP-11), align and distribute (NL-MARKUP-12), arrange (NL-MARKUP-13), the hyperlink's
/// destination and the image tool (NL-MARKUP-17). The menu bar, the context menu and the style
/// strip all call these, so each verb has one implementation.
@MainActor
enum MarkupRound2Actions {

    /// The dialogue identifiers, for `ZenitModalPresenter.didRequest(_:)`.
    static let editLinkIdentifier = "markup.editLink"
    static let insertImageIdentifier = "markup.insertImage"

    // MARK: Group, arrange, align

    static func group(_ core: AppCoreEnvironment) {
        let ids = Array(core.canvas.selectedMarkupIDs)
        Task { @MainActor in
            if let failure = await core.groupMarkups(ids) { core.status.setActiveToolNote(failure) }
            // The group is the selection now, so clicking any member keeps all of it.
            core.canvas.select(markupIDs: core.expandingGroups(Set(ids)), additive: false)
        }
    }

    static func ungroup(_ core: AppCoreEnvironment) {
        let ids = Array(core.canvas.selectedMarkupIDs)
        Task { @MainActor in
            if let failure = await core.ungroupMarkups(ids) { core.status.setActiveToolNote(failure) }
        }
    }

    static func arrange(_ arrangement: MarkupArrangement, core: AppCoreEnvironment) {
        let ids = Array(core.canvas.selectedMarkupIDs)
        Task { @MainActor in
            if let failure = await core.arrangeMarkups(ids, arrangement) { core.status.setActiveToolNote(failure) }
        }
    }

    static func align(_ alignment: MarkupAlignment, core: AppCoreEnvironment) {
        // The first selected markup is the key object Same Width / Same Height copy from.
        let ids = orderedSelection(core)
        Task { @MainActor in
            if let failure = await core.layOutMarkups(ids, alignment) { core.status.setActiveToolNote(failure) }
        }
    }

    /// The selection in draw order, so "the first markup" is stable.
    static func orderedSelection(_ core: AppCoreEnvironment) -> [UUID] {
        let selected = core.canvas.selectedMarkupIDs
        return core.snapshot.markups.map(\.id).filter(selected.contains)
    }

    // MARK: Hyperlink (NL-MARKUP-17)

    /// Reads what a person typed for a link: an `http`, `https` or `mailto` address, or a sheet
    /// — its number in the set (1-based) or its label. `nil` when it is neither.
    static func parseLink(_ text: String, pages: [ZPDFUIPresentation.PageDescriptor]) -> MarkupLinkTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let asURL = MarkupLinkTarget(url: trimmed)
        if asURL.isValid { return asURL }
        if let page = pages.first(where: { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return MarkupLinkTarget(pageID: PageID(page.id))
        }
        if let number = Int(trimmed), number >= 1, number <= pages.count {
            return MarkupLinkTarget(pageID: PageID(pages[number - 1].id))
        }
        return nil
    }

    /// Test seam: the words typed into the link field before the alert is answered.
    static var typeLinkForTesting: String?

    /// Asks for the selected hyperlink's destination and writes it as one undo step.
    static func editLink(_ core: AppCoreEnvironment, window: NSWindow?) {
        guard core.canvas.selectedMarkupIDs.count == 1, let id = core.canvas.selectedMarkupIDs.first,
              let summary = core.snapshot.markups.first(where: { $0.id == id }), summary.kind == .hyperlink else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Select one link to set where it leads.",
                comment: "Status note: Edit Link needs one hyperlink markup selected"
            ))
            return
        }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Where does this link lead?", comment: "Edit Link dialogue title")
        alert.informativeText = NSLocalizedString(
            "Type a web address (https://…), or a sheet's number or name in this project.",
            comment: "Edit Link dialogue detail"
        )
        let field = NSTextField(string: summary.linkURL ?? summary.linkPageID.flatMap { pageID in
            core.document.pages.first { $0.id == pageID }?.label
        } ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        field.setAccessibilityLabel(NSLocalizedString("Link destination", comment: "Accessibility label of the Edit Link field"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: NSLocalizedString("Set Link", comment: "Edit Link dialogue: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        if let typed = typeLinkForTesting { field.stringValue = typed }
        ZenitModalPresenter.runAlert(alert, identifier: editLinkIdentifier, sheetedOn: window, answerWithoutAUser: .dismissed) { answer in
            guard answer == .button(0) else { return }
            let text = field.stringValue
            guard let target = parseLink(text, pages: core.document.pages) else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "That is not a web address or a sheet of this project, so the link was not changed.",
                    comment: "Status note: Edit Link refused what was typed"
                ))
                return
            }
            Task { @MainActor in
                do {
                    _ = try await core.commands.perform(.setMarkupLink(id: MarkupID(id), link: target))
                } catch {
                    core.status.setActiveToolNote(String(describing: error))
                }
            }
        }
    }

    // MARK: Image (NL-MARKUP-17)

    /// The widest an inserted image is placed, in page points; its height follows its aspect.
    static let insertedImageWidth: Double = 200

    /// An image markup for stored artwork, centred on `centre`.
    static func imageRecord(
        digest: String,
        kind: ZPDFContracts.StampArtworkKind,
        sourceName: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        centre: PDFPointValue,
        pageID: UUID,
        documentID: UUID,
        author: String,
        now: Date,
        newID: UUID = UUID()
    ) -> MarkupRecord {
        let aspect: Double = {
            guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return 1 }
            return Double(pixelWidth) / Double(pixelHeight)
        }()
        let width = insertedImageWidth
        let height = width / aspect
        let page = PageID(pageID)
        return MarkupRecord(
            id: MarkupID(newID),
            documentID: DocumentID(documentID),
            pageID: page,
            kind: .image,
            author: author,
            style: MarkupStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 0.5),
            geometry: MeasurementGeometry(pageID: page, points: [
                PDFPoint(x: centre.x - width / 2, y: centre.y - height / 2),
                PDFPoint(x: centre.x + width / 2, y: centre.y + height / 2)
            ]),
            symbol: MarkupSymbol(
                artworkDigest: digest,
                kind: kind,
                sizePoints: max(width, height),
                sourceName: sourceName
            ),
            createdAt: now,
            modifiedAt: now
        )
    }

    /// The image file types the tool and a drop accept.
    static let imageTypes = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp"]

    /// Places an image file as an image markup on the page in view: imported once into the
    /// project's artwork store, placed at `point` or the middle of the visible page area.
    static func insertImage(from url: URL, at point: PDFPointValue? = nil, document: ZenitPDFProjectDocument) async -> String? {
        guard let core = document.core else { return nil }
        switch await document.importPresetArtwork(.image(url: url)) {
        case let .refused(reason):
            return reason
        case .inspected:
            return nil
        case let .imported(descriptor):
            let viewport = core.canvas.viewport
            let visible = viewport.visiblePageRect
            let centre = point ?? PDFPointValue(
                x: visible.minX + visible.size.width / 2,
                y: visible.minY + visible.size.height / 2
            )
            let record = imageRecord(
                digest: descriptor.digest,
                kind: ZPDFContracts.StampArtworkKind(rawValue: descriptor.kind.rawValue) ?? .raster,
                sourceName: descriptor.sourceName,
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight,
                centre: centre,
                pageID: viewport.pageID,
                documentID: core.snapshot.documentID,
                author: AuthorIdentity.current(),
                now: Date()
            )
            do {
                _ = try await core.commands.perform(.addMarkup(record))
                core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
            } catch {
                return String(describing: error)
            }
            return nil
        }
    }

    /// Edit ▸ Insert Image…: chooses an image file, then places it.
    static func chooseAndInsertImage(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = imageTypes.compactMap { UTType(filenameExtension: $0) }
        panel.message = NSLocalizedString("Choose an image to place on the sheet.", comment: "Insert Image open panel message")
        ZenitModalPresenter.runOpenPanel(panel, identifier: insertImageIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                if let failure = await insertImage(from: url, document: document) {
                    document.core?.status.setActiveToolNote(failure)
                }
            }
        }
    }
}
