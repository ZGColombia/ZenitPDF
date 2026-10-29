import SwiftUI
import UniformTypeIdentifiers
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The sheet that edits one tool preset: what it draws, how it looks, and what it fills in.
///
/// The sheet edits a copy. Cancel throws the copy away, Save hands it back. Nothing on the
/// canvas or in the library changes while the sheet is open.
public struct ToolPresetEditorSheet: View {

    @State private var draft: ToolPresetDraft
    @State private var newDefaultKey: String = ""
    @State private var newDefaultValue: String = ""
    /// Which chooser is open, or `nil`. Two content-type sets, so a person looking for a seal
    /// is not shown every PDF in the project folder.
    @State private var artworkChooser: ArtworkChooser?
    /// The whole artwork import conversation — inspect, choose a page, read the limit, commit.
    /// The view shows what this says and calls what it exposes; nothing about the flow is
    /// decided here, so all of it is provable without a pointer.
    @State private var artwork = ArtworkImportCoordinator()

    private let onSave: (ToolPresetDraft) -> Void
    private let onCancel: () -> Void
    private let importArtwork: ArtworkImportHandler?
    /// The recipes a measurement tool can carry, or `nil` to show no Assembly row (NL-QTY-07).
    private let assemblies: ToolPresetAssemblyCatalog?
    /// The Assembly row's state; `nil` without a catalogue.
    @State private var assembly: ToolPresetAssemblyEditor?

    /// Which artwork chooser is open.
    private enum ArtworkChooser: String, Identifiable {
        case pdf
        case image
        var id: String { rawValue }
    }

    /// - Parameters:
    ///   - draft: the preset being edited, as a copy.
    ///   - onSave: receives the edited copy.
    ///   - onCancel: discards the copy.
    ///   - importArtwork: compiles and stores a chosen PDF page or image. `nil` leaves the
    ///     Artwork row read-only, which is what a preview and a host with no open project get.
    ///   - assemblies: the recipes a measurement tool can carry (NL-QTY-07, ADR-0035 §4). `nil`
    ///     shows no Assembly row, and the `zenit.assembly` default stays a raw column default.
    public init(
        draft: ToolPresetDraft,
        onSave: @escaping (ToolPresetDraft) -> Void,
        onCancel: @escaping () -> Void,
        importArtwork: ArtworkImportHandler? = nil,
        assemblies: ToolPresetAssemblyCatalog? = nil
    ) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
        self.importArtwork = importArtwork
        self.assemblies = assemblies
        self._assembly = State(initialValue: assemblies.map {
            ToolPresetAssemblyEditor(customDefaults: draft.customDefaults, catalog: $0, lengthUnit: draft.displayLengthUnit)
        })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(draft.isNew
                ? NSLocalizedString("New Tool", comment: "Tool preset editor title, creating")
                : NSLocalizedString("Edit Tool", comment: "Tool preset editor title, editing"))
                .zpdfText(.windowTitle, .textPrimary)

            identitySection
            ZPDFHairlineDivider()
            styleSection
            if draft.acceptsArtwork {
                ZPDFHairlineDivider()
                stampSection
            }
            ZPDFHairlineDivider()
            measurementSection
            if let assemblies, draft.markupKind == .measurement, assembly != nil {
                ZPDFHairlineDivider()
                assemblySection(assemblies)
            }
            ZPDFHairlineDivider()
            defaultsSection

            Spacer(minLength: ZPDFSpacing.s)
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 460)
        .background(ZPDFColor.background)
        .fileImporter(
            isPresented: Binding(
                get: { artworkChooser == .pdf },
                set: { if !$0, artworkChooser == .pdf { artworkChooser = nil } }
            ),
            allowedContentTypes: ArtworkImportChoice.pdfContentTypes,
            allowsMultipleSelection: false
        ) { result in
            // **Not page one.** The file is inspected first and its pages offered, which is
            // the import gap that used to be answered by help text.
            handleArtworkChoice(result) { url in await artwork.choosePDF(at: url) }
        }
        .fileImporter(
            isPresented: Binding(
                get: { artworkChooser == .image },
                set: { if !$0, artworkChooser == .image { artworkChooser = nil } }
            ),
            allowedContentTypes: ArtworkImportChoice.imageContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleArtworkChoice(result) { url in await artwork.chooseImage(at: url) }
        }
        .sheet(item: Binding(
            get: { artwork.pendingPDF },
            set: { if $0 == nil { artwork.cancel() } }
        )) { _ in
            ArtworkPDFImportSheet(coordinator: artwork)
        }
        .task(id: ObjectIdentifier(artwork)) {
            // The coordinator is `@State` and outlives a body pass; the handler and the
            // adoption are installed once, here, so the draft the sheet is editing is the
            // draft a successful import points at.
            artwork.importArtwork = importArtwork
            artwork.onImported = { descriptor in draft.adoptArtwork(descriptor) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Tool settings",
            comment: "Accessibility label for the tool preset editor sheet"
        )))
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFInspectorRow(label: NSLocalizedString("Name", comment: "Tool preset field")) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .accessibilityLabel(Text(NSLocalizedString("Tool name", comment: "Accessibility label for the tool name field")))
            }
            ZPDFInspectorRow(label: NSLocalizedString("Category", comment: "Tool preset field")) {
                TextField("", text: $draft.category)
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .accessibilityLabel(Text(NSLocalizedString("Category", comment: "Accessibility label for the tool category field")))
            }
            ZPDFInspectorRow(label: NSLocalizedString("Tool", comment: "Tool preset field")) {
                // Through `setMeasurementKind`, so the markup family follows the tool and a new
                // Count tool reaches the Count palette. Finding BH-317.
                Picker(selection: Binding(
                    get: { draft.measurementKind },
                    set: { draft.setMeasurementKind($0) }
                )) {
                    Text(NSLocalizedString("No measurement", comment: "Tool preset: preset does not measure"))
                        .tag(MeasurementKind?.none)
                    ForEach(MeasurementKind.allCases) { kind in
                        Text(kind.displayName).tag(MeasurementKind?.some(kind))
                    }
                } label: {
                    Text(NSLocalizedString("Tool", comment: "Tool preset field"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .zpdfFont(.control)
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFInspectorRow(label: NSLocalizedString("Colour", comment: "Tool preset field")) {
                ToolPresetColorPicker(color: $draft.colorRGBA)
            }
            if draft.markupKind == .count || draft.measurementKind == .count {
                // The same rule as the options bar: only a Count tool draws a symbol.
                ZPDFInspectorRow(label: NSLocalizedString("Symbol", comment: "Tool preset field")) {
                    ToolPresetSymbolPicker(symbolName: $draft.countSymbolName)
                }
            }
            ZPDFInspectorRow(label: NSLocalizedString("Length unit", comment: "Tool preset field")) {
                ZPDFUnitPicker(
                    selection: Binding(
                        get: { draft.displayLengthUnit.rawValue },
                        set: { draft.displayLengthUnit = LengthUnit(rawValue: $0) ?? .metre }
                    ),
                    options: LengthUnit.allCases.map {
                        ZPDFUnitOption(id: $0.rawValue, name: $0.displayName, abbreviation: $0.symbol)
                    },
                    accessibilityTitle: NSLocalizedString("Length unit", comment: "Accessibility title for the tool length unit picker")
                )
            }
        }
    }

    /// What the stamp is made of, and — the part that matters most to the person — whether
    /// its artwork will blur.
    ///
    /// The warning is a fact about the imported artwork, stated once, where the person is
    /// choosing it. A scanned-image stamp is marked as such in the preset editor, because a
    /// stamp that looks fine on screen at fit and soft on a plotted A1
    /// is discovered at the worst possible moment otherwise. Vector artwork gets no warning
    /// because there is nothing to warn about: it is drawn as geometry at every zoom.
    @ViewBuilder
    private var stampSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Stamp", comment: "Tool preset editor section header"))
                .zpdfText(.sectionHeader, .textSecondary)

            ZPDFInspectorRow(label: NSLocalizedString("Artwork", comment: "Tool preset field")) {
                Text(stampArtworkDescription)
                    .zpdfText(.control, .textPrimary)
                    .accessibilityLabel(Text(stampArtworkDescription))
            }
            if importArtwork != nil {
                artworkChooserRow
            }
            if let artworkRefusal = artwork.refusal {
                // The importer's own sentence, with the number in it. A refusal that has taken
                // the trouble to say "41 208 contours; the limit is 20 000" must not be
                // flattened into "Import failed" one layer above it.
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                    Image(systemName: "xmark.octagon")
                        .foregroundStyle(ZPDFColor.danger)
                        .accessibilityHidden(true)
                    Text(artworkRefusal)
                        .zpdfText(.caption, .danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString(
                        "Artwork was not imported. %@",
                        comment: "Accessibility label for an artwork import refusal. %@ is the reason"
                    ),
                    artworkRefusal
                )))
            }
            if draft.markupKind == .stamp {
                ZPDFInspectorRow(label: NSLocalizedString("Fields", comment: "Tool preset field")) {
                    Text(stampFieldsDescription)
                        .zpdfText(.control, .textPrimary)
                }
            }
            if let warning = draft.stampSharpnessWarning {
                // Labelled, not colour-only: the house rule, and the reason the row reads as
                // a sentence rather than as an amber dot the estimator has to interpret.
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(ZPDFColor.warning)
                        .accessibilityHidden(true)
                    Text(warning)
                        .zpdfText(.caption, .warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString(
                        "Sharpness warning. %@",
                        comment: "Accessibility label for the stamp raster warning. %@ is the warning"
                    ),
                    warning
                )))
            }
        }
    }

    /// The two ways in: a page of a PDF, or an image file.
    ///
    /// The compiler, the store, the descriptor, the sharpness classification and the
    /// renderer's geometry path all existed and were tested before this row; what did not
    /// exist was a control a person could press. ADR-0011 §4 left the file-chooser flow out of
    /// its scope. This is that flow.
    @ViewBuilder
    private var artworkChooserRow: some View {
        ZPDFInspectorRow(label: NSLocalizedString("Import", comment: "Tool preset field")) {
            HStack(spacing: ZPDFSpacing.s) {
                Button(NSLocalizedString(
                    "PDF Page…", comment: "Import stamp artwork from the first page of a PDF"
                )) {
                    artwork.clearRefusal()
                    artworkChooser = .pdf
                }
                .disabled(artwork.isBusy)
                .help(NSLocalizedString(
                    "Choose a PDF, then choose which of its pages to import as vector artwork. It stays sharp at any zoom.",
                    comment: "Help for the PDF artwork import button"
                ))
                Button(NSLocalizedString(
                    "Image…", comment: "Import stamp artwork from an image file"
                )) {
                    artwork.clearRefusal()
                    artworkChooser = .image
                }
                .disabled(artwork.isBusy)
                .help(NSLocalizedString(
                    "Import an image as artwork. It is marked as an image and resamples when magnified.",
                    comment: "Help for the image artwork import button"
                ))
                if artwork.isBusy {
                    Text(NSLocalizedString(
                        "Reading…", comment: "Shown while imported artwork is being compiled"
                    ))
                    .zpdfText(.caption, .textSecondary)
                }
                if draft.stamp?.artwork != nil, !artwork.isBusy {
                    Button(NSLocalizedString(
                        "Remove", comment: "Remove a preset's imported artwork"
                    )) {
                        artwork.clearRefusal()
                        // A Count preset loses the whole template, a stamp only the picture.
                        // Finding BH-318.
                        draft.removeArtwork()
                    }
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Remove artwork", comment: "Accessibility label for removing a preset's imported artwork"
                    )))
                }
            }
        }
        .zpdfFont(.control)
    }

    /// Hands a chooser result to the coordinator, or shows why the chooser itself failed.
    private func handleArtworkChoice(
        _ result: Result<[URL], any Error>,
        run: @escaping (URL) async -> Void
    ) {
        artworkChooser = nil
        guard importArtwork != nil else { return }
        switch result {
        case let .failure(error):
            artwork.report(refusal: error.localizedDescription)
        case let .success(urls):
            guard let url = urls.first else { return }
            Task { @MainActor in await run(url) }
        }
    }

    /// A one-line description of the stamp's artwork, for the editor row.
    private var stampArtworkDescription: String {
        Self.artworkDescription(for: draft)
    }

    /// The Artwork row's text for a draft.
    ///
    /// A preset with no picture — no template at all, or a template whose artwork was removed
    /// — reads by what it will draw: a stamp its fields, a Count mark its chosen symbol. The
    /// second case used to say "Fields only" on a Count preset whose template had lost its
    /// picture, although a count mark has no fields. Finding BH-850.
    static func artworkDescription(for draft: ToolPresetDraft) -> String {
        guard let artwork = draft.stamp?.artwork else {
            return draft.markupKind == .stamp
                ? NSLocalizedString("Fields only", comment: "Stamp artwork row, a stamp with no artwork")
                : NSLocalizedString(
                    "The chosen symbol",
                    comment: "Artwork row on a Count preset that draws its picked glyph"
                )
        }
        let format = NSLocalizedString(
            "%1$@ — %2$@", comment: "Stamp artwork row. 1: artwork kind, 2: source file name"
        )
        return String(
            format: format,
            artwork.kind.displayName,
            artwork.sourceName.isEmpty
                ? NSLocalizedString("imported", comment: "Stamp artwork with no recorded file name")
                : artwork.sourceName
        )
    }

    /// The stamp's dynamic fields, named, so the estimator can see what will be filled in.
    private var stampFieldsDescription: String {
        guard let stamp = draft.stamp, !stamp.fields.isEmpty else {
            return NSLocalizedString("None", comment: "Stamp fields row, no dynamic fields")
        }
        return stamp.fields.map(\.kind.displayName).joined(separator: ", ")
    }

    /// The parameters that make this a takeoff tool rather than a drawing tool.
    ///
    /// A preset called `Roof 6:12` that carries the pitch is the difference between the two. Only the parameters the chosen
    /// tool uses are shown — the same rule the options bar applies, so a Length tool never asks
    /// for a wall height (IM-157). A hidden value is left exactly as it is.
    ///
    /// Every field reads through ``ToolPresetParameterRule``, the rule the importer applies,
    /// and says under itself what is wrong with its value; Save stays off while anything is
    /// (IM-036). Lengths are typed in the preset's own display unit and stored in metres; the
    /// two conversions live in ``ToolPresetLengthField`` so they cannot disagree.
    @ViewBuilder
    private var measurementSection: some View {
        let shown = draft.displayedParameterFields
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString(
                "Measurement",
                comment: "Heading for the measurement parameters in the tool preset editor"
            ))
            .zpdfText(.sectionHeader, .textSecondary)
            .textCase(.uppercase)

            if shown.isEmpty {
                Text(NSLocalizedString(
                    "This tool takes no measurement parameters.",
                    comment: "Tool preset editor: the chosen tool uses none of the parameter fields"
                ))
                .zpdfText(.caption, .textSecondary)
            }
            if shown.contains(.depth) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.depth.displayName) {
                    ToolPresetLengthField(
                        quantity: $draft.measurementDefaults.depth,
                        isUnparsed: unparsedBinding(.depth),
                        unit: draft.displayLengthUnit,
                        accessibilityLabel: NSLocalizedString(
                            "Default depth", comment: "Accessibility label for the preset depth field"
                        ),
                        issue: draft.parameterIssue(for: .depth)?.message
                    )
                }
            }
            if shown.contains(.wallHeight) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.wallHeight.displayName) {
                    ToolPresetLengthField(
                        quantity: $draft.measurementDefaults.wallHeight,
                        isUnparsed: unparsedBinding(.wallHeight),
                        unit: draft.displayLengthUnit,
                        accessibilityLabel: NSLocalizedString(
                            "Default wall height", comment: "Accessibility label for the preset wall height field"
                        ),
                        issue: draft.parameterIssue(for: .wallHeight)?.message
                    )
                }
            }
            if shown.contains(.wallHeightAtEnd) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.wallHeightAtEnd.displayName) {
                    ToolPresetLengthField(
                        quantity: $draft.measurementDefaults.wallHeightAtEnd,
                        isUnparsed: unparsedBinding(.wallHeightAtEnd),
                        unit: draft.displayLengthUnit,
                        accessibilityLabel: NSLocalizedString(
                            "Wall height at the far end",
                            comment: "Accessibility label for the preset gable height field"
                        ),
                        issue: draft.parameterIssue(for: .wallHeightAtEnd)?.message
                    )
                }
            }
            if shown.contains(.slopePercent) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.slopePercent.displayName) {
                    ToolPresetNumberField(
                        value: $draft.measurementDefaults.slopePercent,
                        isUnparsed: unparsedBinding(.slopePercent),
                        accessibilityLabel: NSLocalizedString(
                            "Slope percentage", comment: "Accessibility label for the preset slope field"
                        ),
                        issue: draft.parameterIssue(for: .slopePercent)?.message
                    )
                }
            }
            if shown.contains(.slopeAzimuthDegrees) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.slopeAzimuthDegrees.displayName) {
                    ToolPresetNumberField(
                        value: $draft.measurementDefaults.slopeAzimuthDegrees,
                        isUnparsed: unparsedBinding(.slopeAzimuthDegrees),
                        accessibilityLabel: NSLocalizedString(
                            "Fall-line azimuth in degrees",
                            comment: "Accessibility label for the preset slope azimuth field"
                        ),
                        issue: draft.parameterIssue(for: .slopeAzimuthDegrees)?.message
                    )
                }
            }
            if shown.contains(.slopePercent), draft.measurementDefaults.slopeIsMissingAzimuth {
                // Stated, never enforced. ADR-0004 §1 lets a sloped *area* be computed without a
                // fall line and refuses a sloped *length* without one, so the honest thing is to
                // say what is missing and let the estimator decide whether it matters.
                Text(NSLocalizedString(
                    "This tool has a slope but no direction. Sloped areas will be correct; sloped lengths and perimeters need the fall line.",
                    comment: "Note under the tool preset slope fields when the azimuth is missing"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if shown.contains(.volumeDepthReference) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.volumeDepthReference.displayName) {
                    Picker(selection: $draft.measurementDefaults.volumeDepthReference) {
                        Text(NSLocalizedString("Ask when placed", comment: "Tool preset: no volume depth reference stored"))
                            .tag(ToolPresetVolumeDepthReference?.none)
                        ForEach(ToolPresetVolumeDepthReference.allCases) { reference in
                            Text(reference.displayName).tag(ToolPresetVolumeDepthReference?.some(reference))
                        }
                    } label: {
                        Text(NSLocalizedString("Volume depth", comment: "Tool preset field"))
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).zpdfFont(.control)
                }
            }
            if shown.contains(.cutoutPolicy) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.cutoutPolicy.displayName) {
                    Picker(selection: $draft.measurementDefaults.cutoutPolicy) {
                        ForEach(ToolPresetCutoutPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    } label: {
                        Text(NSLocalizedString("Cutouts", comment: "Tool preset field"))
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).zpdfFont(.control)
                }
            }
            if shown.contains(.perimeterPolicy) {
                ZPDFInspectorRow(label: ToolPresetParameterRule.Field.perimeterPolicy.displayName) {
                    Picker(selection: $draft.measurementDefaults.perimeterPolicy) {
                        ForEach(ToolPresetPerimeterPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    } label: {
                        Text(NSLocalizedString("Perimeter", comment: "Tool preset field"))
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).zpdfFont(.control)
                }
            }
            // A stored value the chosen tool does not show can still be one the importer would
            // refuse; say so rather than leave Save off for no visible reason.
            ForEach(draft.parameterIssues.filter { !shown.contains($0.field) }) { issue in
                ToolPresetFieldIssue(message: String(
                    format: NSLocalizedString(
                        "%1$@ (not used by this tool): %2$@",
                        comment: "Tool preset editor: issue in a hidden parameter. 1: field name, 2: the issue"
                    ),
                    issue.field.displayName,
                    issue.message
                ))
            }
        }
    }

    private func unparsedBinding(_ field: ToolPresetParameterRule.Field) -> Binding<Bool> {
        Binding(
            get: { draft.unparsedFields.contains(field) },
            set: { isUnparsed in
                if isUnparsed {
                    draft.unparsedFields.insert(field)
                } else {
                    draft.unparsedFields.remove(field)
                }
            }
        )
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFInspectorRow(label: NSLocalizedString("Label", comment: "Tool preset field")) {
                TextField("", text: $draft.labelPattern)
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Default ledger label",
                        comment: "Accessibility label for the tool default label field"
                    )))
            }
            ZPDFInspectorRow(label: NSLocalizedString("Status", comment: "Tool preset field")) {
                Picker(selection: $draft.defaultStatus) {
                    ForEach(MarkupStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                } label: {
                    Text(NSLocalizedString("Status", comment: "Tool preset field"))
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).zpdfFont(.control)
            }
            ZPDFInspectorRow(label: NSLocalizedString("Origin", comment: "Tool preset field")) {
                Text(draft.provenance.displayDescription)
                    .zpdfText(.control, .textSecondary)
            }
            ZPDFInspectorRow(label: NSLocalizedString("Subject", comment: "Tool preset field")) {
                TextField("", text: $draft.defaultSubject)
                    .textFieldStyle(.roundedBorder)
                    .zpdfFont(.control)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Default takeoff subject",
                        comment: "Accessibility label for the tool default subject field"
                    )))
            }
            Text(NSLocalizedString(
                "Column defaults",
                comment: "Heading for the custom column defaults in the tool preset editor"
            ))
            .zpdfText(.sectionHeader, .textSecondary)
            .textCase(.uppercase)

            ForEach(listedDefaultKeys, id: \.self) { key in
                HStack(spacing: ZPDFSpacing.s) {
                    Text(key).zpdfText(.control, .textPrimary).frame(width: 120, alignment: .leading)
                    Text(draft.customDefaults[key] ?? "").zpdfText(.control, .textSecondary)
                    Spacer(minLength: ZPDFSpacing.s)
                    ZPDFToolbarButton(
                        glyph: .symbol(.remove),
                        title: String(
                            format: NSLocalizedString("Remove %@", comment: "Remove a column default. %@ is the column name"),
                            key
                        ),
                        action: { draft.customDefaults.removeValue(forKey: key) }
                    )
                }
            }

            HStack(spacing: ZPDFSpacing.s) {
                TextField(
                    NSLocalizedString("Column", comment: "Placeholder for a new column default key"),
                    text: $newDefaultKey
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .frame(width: 120)
                // Return here adds the pair. It used to reach Save instead, which closed the
                // sheet and dropped the typed pair. Finding BH-851.
                .onSubmit(addDefault)
                .accessibilityLabel(Text(NSLocalizedString(
                    "New column default name", comment: "Accessibility label for a new column default key field"
                )))
                TextField(
                    NSLocalizedString("Value", comment: "Placeholder for a new column default value"),
                    text: $newDefaultValue
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .onSubmit(addDefault)
                .accessibilityLabel(Text(NSLocalizedString(
                    "New column default value", comment: "Accessibility label for a new column default value field"
                )))
                ZPDFToolbarButton(
                    glyph: .symbol(.add),
                    title: NSLocalizedString("Add Column Default", comment: "Add a custom column default"),
                    action: addDefault
                )
                .disabled(newDefaultKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Toggle(isOn: $draft.isFavorite) {
                Text(NSLocalizedString("Favourite", comment: "Tool preset favourite switch"))
                    .zpdfText(.caption, .textSecondary)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: ZPDFSpacing.m)
            Button(NSLocalizedString("Cancel", comment: "Cancel the tool preset editor"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Save", comment: "Save the tool preset")) {
                // A pair still sitting in the Column/Value fields is saved with the preset
                // rather than thrown away with the sheet (BH-851).
                var saved = draft
                saved.addColumnDefault(key: newDefaultKey, value: newDefaultValue)
                // NL-QTY-07: the Assembly row writes the preset's `zenit.assembly` default.
                if let assemblies, let assembly, saved.markupKind == .measurement {
                    do { try assembly.apply(to: &saved.customDefaults, catalog: assemblies) } catch { return }
                }
                onSave(saved)
            }
            // While a column default is being typed, Return belongs to that pair.
            .keyboardShortcut(Self.saveTakesReturn(pendingColumnName: newDefaultKey) ? .defaultAction : nil)
            .disabled(!draft.isValid || assemblyRefusal != nil)
        }
    }

    /// The column defaults the raw list shows: all of them, except the assembly default while
    /// the Assembly row edits it — a hundred and ninety characters of assignment text is not a
    /// value anybody should read or retype. An assignment this copy cannot read stays listed.
    private var listedDefaultKeys: [String] {
        let keys = draft.customDefaults.keys.sorted()
        guard assemblies != nil, draft.markupKind == .measurement,
              let assembly, assembly.unreadableStoredText == nil else { return keys }
        return keys.filter { $0 != ToolPresetAssemblyCatalog.defaultKey }
    }

    /// Why the Assembly row blocks Save, or `nil`.
    private var assemblyRefusal: ToolPresetAssemblyEditor.Refusal? {
        guard let assemblies, let assembly, draft.markupKind == .measurement else { return nil }
        return assembly.refusal(in: assemblies)
    }

    /// The Assembly row (NL-QTY-07, ADR-0035 §4): a recipe, then its inputs. Saved as the
    /// preset's `zenit.assembly` column default, so every markup drawn with it derives the
    /// recipe's rows.
    @ViewBuilder
    private func assemblySection(_ catalog: ToolPresetAssemblyCatalog) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Assembly", comment: "Heading for the assembly a tool preset carries"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
            ZPDFInspectorRow(label: NSLocalizedString("Recipe", comment: "Tool preset field: the assembly recipe")) {
                Picker(selection: Binding(
                    get: { assembly?.selectedID },
                    set: { assembly?.selectedID = $0 }
                )) {
                    Text(NSLocalizedString("None", comment: "Tool preset assembly: no recipe")).tag(UUID?.none)
                    ForEach(catalog.recipes) { recipe in
                        Text(recipe.name).tag(UUID?.some(recipe.id))
                    }
                } label: {
                    Text(NSLocalizedString("Recipe", comment: "Tool preset field: the assembly recipe"))
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).zpdfFont(.control)
                .accessibilityLabel(Text(NSLocalizedString("Assembly recipe", comment: "Accessibility label for the tool preset assembly picker")))
            }
            if let editor = assembly {
                if editor.unreadableStoredText != nil, editor.selectedID == nil {
                    Text(NSLocalizedString(
                        "This tool carries an assembly this copy of Zenit PDF cannot read. It is kept as it is unless you choose a recipe.",
                        comment: "Tool preset editor: the stored assembly names an unknown recipe"
                    ))
                    .zpdfText(.caption, .textSecondary)
                }
                if let recipe = editor.recipe(in: catalog) {
                    if let note = recipe.note {
                        Text(note).zpdfText(.caption, .textSecondary)
                    }
                    ForEach(editor.inputs(in: catalog), id: \.name) { input in
                        assemblyInputRow(input, unit: editor.unitLabel(for: input))
                    }
                    if let refusal = assemblyRefusal {
                        Text(refusal.message).zpdfText(.caption, .textSecondary)
                    }
                }
            }
        }
    }

    /// One recipe input: a field, and the unit it is typed in.
    private func assemblyInputRow(_ input: LedgerAssemblySummary.Input, unit: String) -> some View {
        ZPDFInspectorRow(label: input.name) {
            HStack(spacing: ZPDFSpacing.s) {
                TextField(
                    input.isFreeParameter
                        ? NSLocalizedString("Required", comment: "Placeholder: an assembly value the estimator must give")
                        : NSLocalizedString("From the measurement", comment: "Placeholder: an assembly value the drawn markup can supply"),
                    text: Binding(
                        get: { assembly?.parameterTexts[input.name] ?? "" },
                        set: { assembly?.parameterTexts[input.name] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .zpdfFont(.control)
                .accessibilityLabel(Text(unit.isEmpty ? input.name : String(
                    format: NSLocalizedString("%1$@ in %2$@", comment: "Accessibility label: an assembly input and its unit"),
                    input.name, unit
                )))
                .help(input.note ?? "")
                if !unit.isEmpty {
                    Text(unit).zpdfText(.control, .textSecondary)
                }
            }
        }
    }

    private func addDefault() {
        guard draft.addColumnDefault(key: newDefaultKey, value: newDefaultValue) else { return }
        newDefaultKey = ""
        newDefaultValue = ""
    }

    /// Whether Save answers Return: not while a column default name is being typed, so Return
    /// adds that pair instead of saving past it. Finding BH-851.
    static func saveTakesReturn(pendingColumnName: String) -> Bool {
        pendingColumnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A named-swatch colour chooser.
///
/// Zenit picks from a fixed palette with spoken names rather than an open colour well, so a
/// preset's colour always has a word attached to it and never carries meaning by hue alone.
public struct ToolPresetColorPicker: View {

    @Binding private var color: ColorRGBA
    @FocusState private var focusedID: String?

    /// Creates the picker.
    public init(color: Binding<ColorRGBA>) {
        self._color = color
    }

    /// The swatches offered: the twelve markup inks of the one Zenit palette (NL-MARKUP-14,
    /// round 2), the same the Inspector, the style strip and the context menu offer.
    static var entries: [ZenitMarkupPalette.Entry] {
        ZPDFMarkupInk.allCases.map { ZenitMarkupPalette.Entry(id: $0.rawValue, name: $0.displayName, color: $0.color) }
    }

    public var body: some View {
        let entries = Self.entries
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ForEach([Array(entries.prefix(6)), Array(entries.dropFirst(6))], id: \.first?.id) { row in
                HStack(spacing: ZPDFSpacing.xs) {
                    ForEach(row) { entry in swatch(entry) }
                }
            }
            // A custom colour, for a company standard the inks do not have (NL-MARKUP-14). A
            // plain, fully opaque system well: nothing is layered over it.
            ColorPicker(
                NSLocalizedString("Custom colour", comment: "Tool preset editor: choose any colour"),
                selection: Binding(
                    get: { color.swiftUIColor },
                    set: { picked in
                        if let converted = NSColor(picked).usingColorSpace(.sRGB) {
                            color = ColorRGBA(
                                red: Double(converted.redComponent),
                                green: Double(converted.greenComponent),
                                blue: Double(converted.blueComponent),
                                alpha: 1
                            )
                        }
                    }
                ),
                supportsOpacity: false
            )
            .zpdfFont(.control)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Colour", comment: "Accessibility label for the tool colour picker")))
    }

    private func swatch(_ entry: ZenitMarkupPalette.Entry) -> some View {
        let isSelected = ZPDFColourMath.sameHue(entry.color, color)
        return Button {
            color = entry.color
        } label: {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(entry.color.swiftUIColor)
                .frame(width: 22, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .strokeBorder(
                            isSelected ? ZPDFColor.textPrimary : ZPDFColor.border,
                            lineWidth: isSelected ? ZPDFStroke.emphasis : ZPDFStroke.regular
                        )
                }
                .overlay {
                    if isSelected {
                        ZPDFGlyphView(.symbol(.success), size: ZPDFSpacing.Control.iconSmall)
                            .foregroundStyle(ZPDFColor.background)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($focusedID, equals: entry.id)
        .zpdfFocusRing(focusedID == entry.id, cornerRadius: ZPDFRadius.small)
        .help(entry.name)
        .accessibilityLabel(Text(entry.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A picker for the Count symbol, from a short list of plain system symbol names.
///
/// The list is fixed in code. A preset can never name an arbitrary image to load, which is what
/// keeps an imported tool set from reaching outside itself.
public struct ToolPresetSymbolPicker: View {

    @Binding private var symbolName: String?

    /// The symbol names a Count preset may use.
    ///
    /// **Ten names for the renderer's ten glyphs**, and that correspondence is the point. Until
    /// this build the list was a list of pictures: it offered `hexagon`, which the renderer has
    /// never been able to draw, and omitted the star and the filled diamond, which it can. The
    /// canvas drew a hard-coded dot for all of them, so nothing ever noticed. The join is
    /// `ZPDFAppCore.CountSymbolCatalogue`, which cannot be imported here — this package depends
    /// on the presentation seam and nothing else — so the two lists are held in agreement by
    /// `CountSymbolWiringTests.thePickerOffersExactlyTheCataloguedSymbols`, in the application
    /// test target, which links both.
    public static let allowedSymbolNames = [
        "circle.fill", "circle", "square.fill", "square", "triangle.fill",
        "triangle", "diamond.fill", "xmark", "plus", "star.fill"
    ]

    /// A localized name for one of ``allowedSymbolNames``. An unknown name reads as "Symbol"
    /// rather than as an identifier.
    public static func displayName(forSymbol name: String) -> String {
        switch name {
        case "circle.fill": return NSLocalizedString("Filled circle", comment: "Count symbol name")
        case "circle": return NSLocalizedString("Circle", comment: "Count symbol name")
        case "square.fill": return NSLocalizedString("Filled square", comment: "Count symbol name")
        case "square": return NSLocalizedString("Square", comment: "Count symbol name")
        case "triangle.fill": return NSLocalizedString("Filled triangle", comment: "Count symbol name")
        case "triangle": return NSLocalizedString("Triangle", comment: "Count symbol name")
        case "diamond.fill": return NSLocalizedString("Filled diamond", comment: "Count symbol name")
        case "xmark": return NSLocalizedString("Cross", comment: "Count symbol name")
        case "plus": return NSLocalizedString("Plus", comment: "Count symbol name")
        case "star.fill": return NSLocalizedString("Filled star", comment: "Count symbol name")
        default: return NSLocalizedString("Symbol", comment: "Count symbol name for an unknown symbol")
        }
    }

    /// Creates the picker.
    public init(symbolName: Binding<String?>) {
        self._symbolName = symbolName
    }

    public var body: some View {
        Picker(selection: $symbolName) {
            Text(NSLocalizedString("None", comment: "Tool preset: no count symbol")).tag(String?.none)
            ForEach(Self.allowedSymbolNames, id: \.self) { name in
                // The spoken name, not the SF Symbols identifier: the menu used to read
                // "circle.fill" and "xmark" aloud. IM-234.
                Label(Self.displayName(forSymbol: name), systemImage: name).tag(String?.some(name))
            }
        } label: {
            Text(NSLocalizedString("Symbol", comment: "Tool preset field"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .zpdfFont(.control)
        .accessibilityLabel(Text(NSLocalizedString("Count symbol", comment: "Accessibility label for the count symbol picker")))
    }
}

/// The named markup colours Zenit offers: the one shared palette (W-075).
///
/// Each colour has a word, so "the green ones" is also "the Approved ones" for someone who
/// cannot tell them apart. This used to be its own literal copy of the five entries; zones and
/// revision overlays read it under this name.
public typealias ZenitMarkupPalette = ZenitNamedPalette
