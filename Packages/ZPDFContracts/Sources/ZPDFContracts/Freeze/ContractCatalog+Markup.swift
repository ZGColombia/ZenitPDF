import Foundation

extension ContractCatalog {

    static func markupContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(.enumeration(
            MarkupKind.self,
            name: "MarkupKind",
            summary: "The markup types the product creates (spec 14.1).",
            note: { $0.producesQuantity ? "reaches the Quantity Ledger" : nil }
        ))

        types.append(.enumeration(
            MarkupStatus.self,
            name: "MarkupStatus",
            summary: "Review status of a markup (spec 14.3).",
            invariants: [
                "`none` is a state of its own, so \"not part of a review workflow\" never has to be spelled as an absent value each consumer interprets differently.",
                "Status is never signalled by colour alone in the UI."
            ]
        ))

        types.append(.enumeration(
            LineStyle.self,
            name: "LineStyle",
            summary: "Line dash pattern."
        ))

        types.append(.enumeration(
            LineCapStyle.self,
            name: "LineCapStyle",
            summary: "Line end decoration (spec 14.3)."
        ))

        types.append(.enumeration(
            TextAlignment.self,
            name: "TextAlignment",
            summary: "Horizontal text alignment inside a markup's text box."
        ))

        types.append(try .reflecting(
            ContractSamples.markupStyle,
            name: "MarkupStyle",
            summary: "Everything that decides how a markup looks (spec 14.3).",
            annotations: [
                "color": .init("sRGB 0...1", "stroke colour"),
                "fill": .init("sRGB 0...1", "nil means unfilled"),
                "opacity": .init("0...1", "multiplied with the colours' own alpha"),
                "lineWidth": .init("PDF point", "finite and non-negative"),
                "lineStyle": .init("-", "dash pattern"),
                "startCap": .init("-", "line end decoration"),
                "endCap": .init("-", "line end decoration"),
                "fontName": .init("-", "family name only; resolution happens in the design system"),
                "fontSize": .init("PDF point", "finite and positive"),
                "textAlignment": .init("-", "horizontal alignment"),
                "textStyle": .init("-", "bold, italic, text colour and box border (ADR-0029); nil is plain text in the stroke colour, which is what every style written before ADR-0029 means"),
                "cloudArcSize": .init("PDF point", "scallop radius of a clouded outline (ADR-0029); nil is automatic, a set value is clamped to 2...72"),
                "rotationDegrees": .init("degree", "counter-clockwise about the box centre (ADR-0029); nil is none; stamps keep StampInstance.rotationDegrees"),
                "blendMode": .init("-", "normal or multiply (ADR-0029); nil is normal; multiply is the highlighter"),
                "measurementCaption": .init("-", "a measurement's caption fields, segment lengths and dragged label offset (ADR-0030 §3); nil is the headline value at the automatic position")
            ],
            invariants: [
                "Fonts are named, not resolved: this package cannot import AppKit.",
                "measurementCaption is display only: it never holds a quantity, and it is absent from a style that does not use it (ADR-0030 §3).",
                "Every field added by ADR-0029 is optional and absent from a style that does not use it, so a style written before ADR-0029 decodes unchanged and one that does not use the new fields encodes byte-identically."
            ]
        ))

        types.append(try .reflecting(
            MarkupTextStyle.plain,
            name: "MarkupTextStyle",
            summary: "Text formatting beyond family, size and alignment (ADR-0029).",
            annotations: [
                "bold": .init("-", "bold weight"),
                "italic": .init("-", "italic face"),
                "textColor": .init("sRGB 0...1", "nil is the stroke colour"),
                "boxBorder": .init("-", "a Text box draws a border in the stroke colour; a Callout always draws its box")
            ]
        ))

        types.append(.enumeration(
            MarkupBlendMode.self,
            name: "MarkupBlendMode",
            summary: "How a markup's ink combines with the drawing under it (ADR-0029)."
        ))

        types.append(try .reflecting(
            MarkupLinkTarget(url: "https://example.org"),
            name: "MarkupLinkTarget",
            summary: "Where a hyperlink markup leads (ADR-0029).",
            annotations: [
                "pageID": .init("-", "a page of the same project"),
                "url": .init("-", "a web address; http, https or mailto only")
            ],
            invariants: [
                "Exactly one of pageID and url is set (isValid).",
                "Following a web address is always confirmed by a person; nothing opens on its own."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.markup,
            name: "MarkupRecord",
            summary: "One Zenit markup as it lives in the project database (spec 14.2, 14.3).",
            annotations: [
                "id": .init("-", "stable UUID, minted once, never reused, survives export"),
                "documentID": .init("-", "owning document"),
                "pageID": .init("-", "a markup lives on one page"),
                "kind": .init("-", "from the spec 14.1 list"),
                "tool": .init("-", "the measurement tool that created it, for measurement and count kinds"),
                "subject": .init("-", "primary ledger grouping key"),
                "label": .init("-", "secondary ledger key"),
                "comment": .init("-", "free text"),
                "author": .init("-", "local author name; local-first, no account identity"),
                "status": .init("-", "review status"),
                "style": .init("-", "appearance"),
                "caption": .init("-", "optional caption drawn next to the markup"),
                "layerID": .init("-", "the markup layer it belongs to (ADR-0032); nil is the project's default layer, which is every markup written before ADR-0032"),
                "zoneID": .init("-", "optional Project Zone"),
                "scaleRegionID": .init("-", "optional Scale Region"),
                "scaleID": .init("-", "the scale the measurement was computed under"),
                "scaleVersion": .init("-", "the version of that scale; a mismatch means the value is stale"),
                "locked": .init("-", "locked markups reject geometry and style edits"),
                "hidden": .init("-", "hidden markups are not drawn"),
                "printable": .init("-", "excluded from print and flattened export when false"),
                "geometry": .init("PDF point", "original page-space geometry, kept verbatim"),
                "parameters": .init("-", "measurement parameters used"),
                "measurement": .init("SI base units", "computed values"),
                "parentMarkupID": .init("-", "set for a cutout (spec 12.4)"),
                "cutoutMarkupIDs": .init("-", "cutout children in creation order"),
                "countGroupID": .init("-", "the count group, for count markups"),
                "customValues": .init("-", "custom ledger values keyed by column"),
                "stamp": .init("-", "the placed stamp's template identity and its frozen field values (ADR-0010); nil for every non-stamp markup"),
                "symbol": .init("-", "a reference to artwork in the project's content-addressed store, or a built-in glyph name (spec 12.13, ADR-0011); nil for a markup that draws no symbol"),
                "provenance": .init("-", "what kind of claim the row's quantity makes: measured, derived or read (ADR-0012); absent in stored JSON decodes as measured, no migration pass"),
                "derivation": .init("-", "the ancestry of a derived or read row (ADR-0012); mandatory for those two cases, refused for measured, enforced at decode"),
                "groupID": .init("-", "the markup group (ADR-0029); members select, move, restyle and delete as one; nil when ungrouped"),
                "link": .init("-", "a hyperlink markup's destination (ADR-0029); nil on every other kind"),
                "createdAt": .init("-", "supplied by an injected TimestampProviding"),
                "modifiedAt": .init("-", "supplied by an injected TimestampProviding")
            ],
            invariants: [
                "Zenit markups are a first-class overlay in SQLite, not PDF annotations: the id is stable across exports (spec 14.2).",
                "Original PDF geometry is stored alongside the computed SI values, so a scale change recomputes from source rather than from a previously computed number (spec 10.6).",
                "scaleID plus scaleVersion make a stale measurement detectable (isMeasurementStale(against:)).",
                "createdAt and modifiedAt are injected, never read from the wall clock inside a calculation.",
                "A stamp's dynamic fields are resolved once, at placement, and frozen into stamp.fields; they are never re-resolved on read (ADR-0010).",
                "A markup's symbol is a reference and never bytes: artwork lives once per project, keyed by SHA-256, so a markup renders correctly after its preset is deleted or edited and a project stays self-contained when it travels (ADR-0011).",
                "Imported artwork is data. It is bounded by ArtworkLimits, refused with a named reason when it exceeds them, and nothing in an imported file is ever executed (ADR-0011).",
                "Every row states its claim: provenance is measured, derived or read, stored and exported, immutable after commit (ADR-0012). A record with no provenance key decodes as measured, so every project written before ADR-0012 stays readable with no migration pass.",
                "derivation is mandatory for derived and read rows and refused for measured rows; the pairing is enforced at decode and by MarkupRecord.quantityProvenanceViolation() (ADR-0012).",
                "Draw order is the markup's layer, then the document's markup order within that layer: a layer higher in the layer list draws above every layer below it (ADR-0036, answering ADR-0032 section 7). The archive stores the markup order as markup_extra.sort_order; arranging a markup reorders it among its own layer's markups on its page and adds no field (ADR-0029).",
                "A cloud may carry a callout: its polygon ring is the cloud and its points are [leader target, box corner, box corner], with the text in caption. It is one markup, one ledger row and one export annotation (ADR-0029).",
                "A freehand markup stores its sampled points as an open point list; smoothing happens at draw time only (ADR-0029).",
                "Every markup belongs to exactly one markup layer: layerID, or the default layer when layerID is nil or names a layer the project does not hold (effectiveLayerID, ADR-0032).",
                "A markup is drawn when neither it nor its layer is hidden, editable when neither is locked, and printed when both are printable. A layer's flags never change a quantity or remove a row from the Quantity Ledger (ADR-0032)."
            ]
        ))

        types.append(try .reflecting(
            MarkupLayer.makeDefault(),
            name: "MarkupLayer",
            summary: "One markup layer of a project: a named, ordered group of markups that shows, locks and prints together (ADR-0032).",
            annotations: [
                "id": .init("-", "stable UUID; the default layer's is the fixed MarkupLayer.defaultID in every project"),
                "name": .init("-", "display name; not an identity, two layers may share it"),
                "order": .init("-", "place in the list, 0 at the top; consumers sort by it, never by name"),
                "visible": .init("-", "false hides the layer's markups from the canvas and from hit-testing"),
                "locked": .init("-", "true makes the layer's markups refuse selection and every edit"),
                "printable": .init("-", "false keeps the layer's markups off print and flattened export")
            ],
            invariants: [
                "A project always has the default layer; it can be renamed, hidden and locked but never deleted.",
                "Deleting any other layer moves its markups to a layer the person names, in the same undo step.",
                "Hiding a layer is a view decision: its markups stay in the Quantity Ledger and in every total unless the person filters by layer."
            ]
        ))

        types.append(.enumeration(
            QuantityProvenance.self,
            name: "QuantityProvenance",
            summary: "What kind of claim a row's quantity makes: measured, derived, or read (ADR-0012).",
            invariants: [
                "A derived or read row is never mistaken for a measurement: exporters print the provenance, and the ledger renders the difference without relying on colour alone (ADR-0012).",
                "Correcting a read row is an audit-trailed edit on a row that still says read; it is never promoted to measured (ADR-0012)."
            ],
            note: { $0.requiresDerivation ? "derivation is mandatory" : "derivation is refused" }
        ))

        types.append(try .reflecting(
            ContractSamples.quantityDerivation,
            name: "QuantityDerivation",
            summary: "The ancestry of a derived or read row (ADR-0012).",
            annotations: [
                "sourceMarkupID": .init("-", "the measured markup a derived row descends from; nil for a read row"),
                "formulaText": .init("-", "the assembly line's formula text (derived) or the OCR text (read), verbatim"),
                "inputs": .init("-", "the inputs at evaluation time, by name, so the number is reproducible on paper"),
                "originIdentifier": .init("-", "assembly definition id (derived) or page region (read), for the audit trail")
            ],
            invariants: [
                "Mandatory for derived and read rows, refused for measured rows (ADR-0012)."
            ]
        ))

        types.append(.enumeration(
            StampArtworkKind.self,
            name: "StampArtworkKind",
            summary: "What a stamp's artwork is, and therefore whether it stays sharp when magnified.",
            invariants: [
                "Vector artwork stays vector; raster artwork is marked as raster so the editor can say it will blur."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.markupSymbol,
            name: "MarkupSymbol",
            summary: "The symbol a markup draws itself as: a reference to artwork, never the artwork (ADR-0011).",
            annotations: [
                "artworkDigest": .init("-", "SHA-256 of the artwork bytes in the project's artwork store; nil for a built-in glyph"),
                "kind": .init("-", "vector, raster or none — whether magnifying keeps the edges crisp"),
                "builtInGlyph": .init("-", "the built-in count glyph's name, when there is no imported artwork"),
                "sizePoints": .init("PDF point", "edge of the symbol's square box; finite, \(ContractNumberText.range(ArtworkLimits.minimumBoxPoints, ArtworkLimits.maximumBoxPoints))"),
                "rotationDegrees": .init("degree", "counter-clockwise about the mark's own point"),
                "sourceName": .init("-", "the file the artwork was imported from, kept verbatim")
            ],
            invariants: [
                "A symbol is resolved from the project, never from the tool library, so deleting or editing a preset cannot change a mark that was already placed.",
                "Artwork bytes are stored once per digest; 312 batch-placed marks cost one copy and 312 references."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.artworkGeometry,
            name: "ArtworkGeometry",
            summary: "Imported artwork compiled once into unit-space geometry (ADR-0011 §2.2).",
            annotations: [
                "kind": .init("-", "vector from a PDF page, raster from an image"),
                "strokes": .init("unit", "contours to stroke, in the 0...1 artwork box"),
                "regions": .init("unit", "regions to fill, even-odd, in the 0...1 artwork box"),
                "compilerVersion": .init("-", "the compiler that produced this geometry"),
                "sourceAspectRatio": .init("-", "source width divided by source height; finite and positive")
            ],
            invariants: [
                "Vector artwork is geometry, never an image, so magnification multiplies coordinates and cannot resample — a stamp is sharp at 400 %.",
                "A raster source is compiled to a bounded cell mosaic and marked raster, so the editor can say at what magnification it stops adding detail.",
                "Every coordinate is finite and inside the unit box; ArtworkGeometry.limitViolation() is the one place the bounds are enforced."
            ]
        ))

        types.append(.enumeration(
            StampFieldKind.self,
            name: "StampFieldKind",
            summary: "The dynamic content a stamp can carry (ADR-0010).",
            invariants: [
                "Every field resolves at placement time and is frozen into the markup; none is re-resolved on read."
            ]
        ))

        types.append(.enumeration(
            MarkupCommandKind.self,
            name: "MarkupCommandKind",
            summary: "The undoable mutations of the markup engine (spec 14.5).",
            invariants: [
                "Every mutation is a command; NSUndoManager is integrated per document.",
                "The list is frozen because a command name is part of the persisted undo stack."
            ]
        ))

        types.append(.enumeration(
            MarkupExportMode.self,
            name: "MarkupExportMode",
            summary: "The three export shapes (spec 14.2)."
        ))

        return ContractDocument(
            contract: "MARKUP_CONTRACT",
            contractVersion: ContractVersion.markup,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["14.1", "14.2", "14.3", "14.4", "14.5"],
            summary: """
                The markup record: what a Zenit markup is, what it looks like, what it is worth in \
                the ledger, and which mutations the undo stack knows about.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "markupKinds",
                    columns: ["kind", "producesQuantity", "isTextMarkup"],
                    rows: MarkupKind.allCases.map {
                        [$0.rawValue, $0.producesQuantity ? "true" : "false", $0.isTextMarkup ? "true" : "false"]
                    }
                ),
                ContractTable(
                    name: "exportModes",
                    columns: ["mode", "behaviour"],
                    rows: [
                        ["editableAnnotated", "standard PDF annotations where possible, optional Zenit custom dictionary"],
                        ["flattened", "markups drawn into the page content stream"],
                        ["clean", "no Zenit markups at all"]
                    ]
                )
            ],
            invariants: [
                "Live projects keep Zenit markups in SQLite with a stable UUID and a custom overlay; PDF annotations are an export shape, not the storage format (spec 14.2).",
                "Every mutation is an undoable command (spec 14.5).",
                "A locked markup rejects geometry and style edits; a hidden markup is not drawn; a non-printable markup is excluded from print and flattened export.",
                "A cutout points at its parent and appears as a ledger child (spec 12.4).",
                "No competing product's icon, colour, screenshot, layout measurement, wording or distinctive feature name is reproduced anywhere in this contract, and no such product is named."
            ]
        )
    }
}
