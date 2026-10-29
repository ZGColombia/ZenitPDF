import Foundation

/// Everything the UI needs to lay out and label a single PDF page.
///
/// A descriptor is a snapshot: it is produced by the document layer, never mutated by
/// the UI, and is safe to move between actors. Both boxes are in canonical page space.
public struct PageDescriptor: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the page for the lifetime of the open document.
    public let id: UUID
    /// Zero-based position of the page in the document.
    public let index: Int
    /// The PDF page label, for example `"A-101"`. Falls back to the 1-based index when
    /// the document defines no label; the UI must show this, never ``index``.
    public let label: String
    /// The media box in page space.
    public let mediaBox: PDFRectValue
    /// The crop box in page space. Equal to ``mediaBox`` when the page defines no crop box.
    public let cropBox: PDFRectValue
    /// The explicit page rotation.
    public let rotation: PageRotation
    /// The sheet's name, when the drawing gives one — "A1.01 - Floor Plan". Resolved by
    /// ``resolvedSheetTitle(outlineTitle:label:)``: the document's own page label when it is a
    /// name, then the PDF outline entry that points at the page, else `nil`. Never invented, never the bare
    /// 1-based fallback number. Not part of the frozen page contract: it is presentation, read
    /// beside the geometry, and an older encoded descriptor without it decodes as `nil`.
    public let sheetTitle: String?
    /// The sheet number the set gives the page ("A-101"), when it has been named (NL-DOCS-05):
    /// read from the title block or typed. Wins over the label and the outline in
    /// ``sheetTitle``. An older encoded descriptor without it decodes as `nil`.
    public let sheetNumber: String?
    /// Whether ``sheetTitle`` comes from the sheet's own identity (NL-DOCS-05) rather than from
    /// the drawing's label or outline, so a later outline read does not replace it.
    public let hasSheetIdentity: Bool
    /// Degrees clockwise the sheet is turned on screen on top of ``rotation`` (NL-DOCS-07):
    /// 0, 90, 180 or 270. Display only — page space, and every measurement in it, is unchanged.
    public let viewRotation: Int
    /// The part of the page the sheet shows (NL-DOCS-16), in page space; `nil` shows the crop
    /// box. Display only.
    public let viewCrop: PDFRectValue?

    /// Creates a page descriptor.
    public init(
        id: UUID,
        index: Int,
        label: String,
        mediaBox: PDFRectValue,
        cropBox: PDFRectValue,
        rotation: PageRotation,
        sheetTitle: String? = nil,
        sheetNumber: String? = nil,
        hasSheetIdentity: Bool = false,
        viewRotation: Int = 0,
        viewCrop: PDFRectValue? = nil
    ) {
        self.id = id
        self.index = index
        self.label = label
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotation = rotation
        self.sheetTitle = sheetTitle
        self.sheetNumber = sheetNumber
        self.hasSheetIdentity = hasSheetIdentity
        self.viewRotation = ((viewRotation % 360) + 360) % 360 / 90 * 90
        self.viewCrop = viewCrop
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, label, mediaBox, cropBox, rotation, sheetTitle, sheetNumber, hasSheetIdentity
        case viewRotation, viewCrop
    }

    /// Decodes both the current form and one written before sheet identities existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            index: try container.decode(Int.self, forKey: .index),
            label: try container.decode(String.self, forKey: .label),
            mediaBox: try container.decode(PDFRectValue.self, forKey: .mediaBox),
            cropBox: try container.decode(PDFRectValue.self, forKey: .cropBox),
            rotation: try container.decode(PageRotation.self, forKey: .rotation),
            sheetTitle: try container.decodeIfPresent(String.self, forKey: .sheetTitle),
            sheetNumber: try container.decodeIfPresent(String.self, forKey: .sheetNumber),
            hasSheetIdentity: try container.decodeIfPresent(Bool.self, forKey: .hasSheetIdentity) ?? false,
            viewRotation: try container.decodeIfPresent(Int.self, forKey: .viewRotation) ?? 0,
            viewCrop: try container.decodeIfPresent(PDFRectValue.self, forKey: .viewCrop)
        )
    }

    /// The same page with another sheet title. A page named by its sheet identity keeps it.
    public func withSheetTitle(_ title: String?) -> PageDescriptor {
        guard !hasSheetIdentity else { return self }
        return PageDescriptor(
            id: id,
            index: index,
            label: label,
            mediaBox: mediaBox,
            cropBox: cropBox,
            rotation: rotation,
            sheetTitle: title,
            sheetNumber: sheetNumber,
            hasSheetIdentity: false,
            viewRotation: viewRotation,
            viewCrop: viewCrop
        )
    }

    /// The same page named by its sheet identity (NL-DOCS-05): "A-101 · FLOOR PLAN", the number
    /// alone, or the title alone. Both `nil` clears the identity.
    public func withSheetIdentity(number: String?, title: String?) -> PageDescriptor {
        let name = Self.composedSheetName(number: number, title: title)
        return PageDescriptor(
            id: id,
            index: index,
            label: label,
            mediaBox: mediaBox,
            cropBox: cropBox,
            rotation: rotation,
            sheetTitle: name ?? Self.resolvedSheetTitle(outlineTitle: nil, label: label),
            sheetNumber: number,
            hasSheetIdentity: name != nil,
            viewRotation: viewRotation,
            viewCrop: viewCrop
        )
    }

    /// The same page shown turned and cropped (NL-DOCS-07/16).
    public func withView(rotation: Int, crop: PDFRectValue?) -> PageDescriptor {
        PageDescriptor(
            id: id, index: index, label: label, mediaBox: mediaBox, cropBox: cropBox,
            rotation: self.rotation, sheetTitle: sheetTitle, sheetNumber: sheetNumber,
            hasSheetIdentity: hasSheetIdentity, viewRotation: rotation, viewCrop: crop
        )
    }

    /// The page's own `/Rotate` plus its view rotation, 0, 90, 180 or 270: how the sheet stands
    /// on screen.
    public var displayRotation: Int { (rotation.rawValue + viewRotation) % 360 }

    /// What the sheet shows, in page space: the view crop clamped to the crop box, else the
    /// crop box.
    public var viewBox: PDFRectValue {
        guard let crop = viewCrop else { return cropBox }
        let minX = max(crop.minX, cropBox.minX), minY = max(crop.minY, cropBox.minY)
        let maxX = min(crop.maxX, cropBox.maxX), maxY = min(crop.maxY, cropBox.maxY)
        guard maxX > minX, maxY > minY else { return cropBox }
        return PDFRectValue(
            origin: PDFPointValue(x: minX, y: minY),
            size: PDFSizeValue(width: maxX - minX, height: maxY - minY)
        )
    }

    /// The size the sheet occupies on screen, in points: ``viewBox`` after ``displayRotation``.
    public var viewSize: PDFSizeValue {
        let box = viewBox
        return (displayRotation == 90 || displayRotation == 270)
            ? PDFSizeValue(width: box.size.height, height: box.size.width)
            : box.size
    }

    /// "A-101 · FLOOR PLAN", the number alone, the title alone, or `nil`.
    public static func composedSheetName(number: String?, title: String?) -> String? {
        let number = number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch (number, title) {
        case let (number?, title?): return "\(number) · \(title)"
        case let (number?, nil): return number
        case let (nil, title?): return title
        case (nil, nil): return nil
        }
    }

    /// The sheet title for a page, in the one order the product uses everywhere:
    /// the page's own label when it is a name rather than a number,
    /// else the outline entry that points at the page, else nothing.
    ///
    /// Whitespace-only text counts as absent. An all-digit label is the reader's 1-based
    /// fallback (or a plain number) — a position, not a name — so it never becomes a title.
    /// When the outline title already contains the label ("A-101 Floor Plan" for label
    /// "A-101") the outline title is used: it says everything the label says, and more.
    public static func resolvedSheetTitle(outlineTitle: String?, label: String) -> String? {
        let outline = outlineTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelIsName = !trimmedLabel.isEmpty && !trimmedLabel.allSatisfy(\.isNumber)
        if labelIsName {
            if !outline.isEmpty,
               outline.range(of: trimmedLabel, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return outline
            }
            return trimmedLabel
        }
        return outline.isEmpty ? nil : outline
    }

    /// How sheet numbers are compared: case, spaces and the separator style do not make a
    /// different sheet ("a-101", "A 101", "A101" and "A-101" are one); a dot does ("A1.01").
    ///
    /// The one rule (S-048, iteration 2): the core's sheet lookups and the shell's page field
    /// both use it, so a typed number reaches the same sheet everywhere.
    public static func normalisedSheetNumber(_ number: String) -> String {
        String(number.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." })
    }

    /// The box the canvas draws and hit-tests against: the crop box.
    public var visibleBox: PDFRectValue { cropBox }

    /// The visible size after ``rotation`` is applied, in PDF points.
    public var rotatedVisibleSize: PDFSizeValue {
        rotation.swapsAxes
            ? PDFSizeValue(width: cropBox.size.height, height: cropBox.size.width)
            : cropBox.size
    }

    /// A localized "1-based index of count" description, for VoiceOver.
    public func accessibilityLabel(pageCount: Int) -> String {
        let format = NSLocalizedString(
            "Page %1$@, %2$d of %3$d",
            comment: "VoiceOver label for a PDF page: page label, position, total page count"
        )
        return String(format: format, label, index + 1, pageCount)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
