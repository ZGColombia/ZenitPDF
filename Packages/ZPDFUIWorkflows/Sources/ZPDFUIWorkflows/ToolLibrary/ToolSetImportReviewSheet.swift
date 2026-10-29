import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Shows exactly what an imported tool set contains, before a single tool is added.
///
/// This sheet exists because a tool set arrives from outside. The person reading it may have got
/// it in an email. So Zenit lists what is in the file — the tools, the symbols, the pictures, the
/// defaults it wants to write — states plainly that none of it will be run, and only then offers
/// the Import button.
public struct ToolSetImportReviewSheet: View {

    private let review: ToolSetImportReview
    private let onImport: () -> Void
    private let onCancel: () -> Void
    /// Whether an accepted picture can actually reach the project: the host has installed an
    /// artwork importer. ``ToolLibraryEditingModel/canKeepImportedPictures``.
    private let canKeepPictures: Bool
    /// Adds the reviewed tools the chosen way, when the host offers a choice (IM-233).
    private let onImportWithStrategy: ((ToolSetImportStrategy) -> Void)?

    /// How arriving tools that are already in the library are treated.
    @State private var strategy: ToolSetImportStrategy = .keepBoth

    @State private var expandedSection: Section? = .contents

    private enum Section: Hashable {
        case contents
        case symbols
        case images
        case defaults
        case findings
    }

    /// - Parameters:
    ///   - review: what the validator found.
    ///   - onImport: adds the reviewed tools.
    ///   - onCancel: closes without adding anything.
    ///   - canKeepPictures: whether an accepted picture will be attached to its tool.
    public init(
        review: ToolSetImportReview,
        onImport: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        canKeepPictures: Bool = false,
        onImportWithStrategy: ((ToolSetImportStrategy) -> Void)? = nil
    ) {
        self.review = review
        self.onImport = onImport
        self.onCancel = onCancel
        self.canKeepPictures = canKeepPictures
        self.onImportWithStrategy = onImportWithStrategy
    }

    /// Whether the sheet offers Keep Both / Update Matching Tools: only when some arriving tool
    /// is already in the library and the host can act on the choice.
    static func offersStrategy(review: ToolSetImportReview, canChoose: Bool) -> Bool {
        canChoose && !review.libraryMatches.isEmpty
    }

    /// The status beside one picture in the review.
    ///
    /// "Will be kept" is said only when it is true: the picture passed every limit **and** the
    /// host can attach it. The sheet used to promise it for every in-limit picture while the
    /// import appended the tools alone and discarded the bytes. Finding BH-320.
    static func imageStatus(isAccepted: Bool, canKeepPictures: Bool) -> String {
        guard isAccepted else {
            return NSLocalizedString("Will be left out", comment: "Import review: image rejected")
        }
        return canKeepPictures
            ? NSLocalizedString("Will be kept", comment: "Import review: image accepted")
            : NSLocalizedString(
                "Cannot be kept here",
                comment: "Import review: an in-limit image that this window has no way to store"
            )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            header
            dataOnlyNote
            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    contentsSection
                    if !review.countSymbolNames.isEmpty { symbolsSection }
                    if !review.embeddedImages.isEmpty { imagesSection }
                    if !review.customDefaultKeys.isEmpty { defaultsSection }
                    if !review.findings.isEmpty { findingsSection }
                }
                .padding(.bottom, ZPDFSpacing.m)
            }
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 560, height: 620)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Review this tool set before importing",
            comment: "Accessibility label for the tool set import review sheet"
        )))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString(
                "Review this tool set before importing",
                comment: "Title of the tool set import review sheet"
            ))
            .zpdfText(.windowTitle, .textPrimary)

            Text(review.setName).zpdfText(.body, .textPrimary)

            HStack(spacing: ZPDFSpacing.s) {
                ZPDFStatusPill(
                    severity: .neutral,
                    title: NSLocalizedString("File", comment: "Import review: file name label"),
                    value: review.fileName,
                    glyph: .symbol(.open),
                    usesMonospacedValue: false
                )
                ZPDFStatusPill(
                    severity: .neutral,
                    title: NSLocalizedString("Size", comment: "Import review: file size label"),
                    value: ByteCountFormatter.string(fromByteCount: Int64(review.byteCount), countStyle: .file),
                    glyph: .symbol(.pages)
                )
                ZPDFStatusPill(
                    severity: .neutral,
                    title: NSLocalizedString("Format", comment: "Import review: schema version label"),
                    value: String(review.schemaVersion),
                    glyph: .symbol(.info)
                )
            }

            if let author = review.declaredAuthor, !author.isEmpty {
                Text(String(
                    format: NSLocalizedString(
                        "The file says it was exported by “%@”. Zenit cannot check that, so treat it as a claim rather than a fact.",
                        comment: "Import review: the declared author is untrusted. %@ is the author string from the file"
                    ),
                    author
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dataOnlyNote: some View {
        ZPDFInlineWarning(
            severity: .info,
            message: ToolSetImportReview.dataOnlyStatement
        )
    }

    // MARK: - Sections

    private var contentsSection: some View {
        section(.contents, title: NSLocalizedString("What this set contains", comment: "Import review section")) {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text(review.summaryLine).zpdfText(.body, .textPrimary)
                if review.droppedPresetCount > 0 {
                    Text(WorkflowPlurals.droppedTools(review.droppedPresetCount))
                    .zpdfText(.caption, .textSecondary)
                }
                ForEach(MarkupKind.allCases) { kind in
                    if let count = review.markupKindCounts[kind], count > 0 {
                        countRow(glyph: WorkflowGlyphs.glyph(for: kind), name: kind.displayName, count: count)
                    }
                }
                ForEach(MeasurementKind.allCases) { kind in
                    if let count = review.measurementKindCounts[kind], count > 0 {
                        countRow(glyph: WorkflowGlyphs.glyph(for: kind), name: kind.displayName, count: count)
                    }
                }
            }
        }
    }

    private var symbolsSection: some View {
        section(.symbols, title: NSLocalizedString("Symbols it asks for", comment: "Import review section")) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(review.countSymbolNames, id: \.self) { name in
                    HStack(spacing: ZPDFSpacing.s) {
                        Image(systemName: name)
                            .foregroundStyle(ZPDFColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(name).zpdfText(.code, .textPrimary)
                    }
                }
            }
        }
    }

    private var imagesSection: some View {
        section(.images, title: NSLocalizedString("Pictures it carries", comment: "Import review section")) {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text(NSLocalizedString(
                    "Zenit has not decoded these yet. It is reporting what the file says about them.",
                    comment: "Import review: embedded images are described, not decoded"
                ))
                .zpdfText(.caption, .textSecondary)
                ForEach(review.embeddedImages) { image in
                    HStack(alignment: .top, spacing: ZPDFSpacing.s) {
                        ZPDFGlyphView(
                            .symbol(image.isAccepted ? .success : .warning),
                            size: ZPDFSpacing.Control.iconSmall
                        )
                        .foregroundStyle(ZPDFColor.color(image.isAccepted ? .success : .warning))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(image.fileName).zpdfText(.control, .textPrimary)
                            Text(image.detailLine).zpdfText(.caption, .textSecondary)
                        }
                        Spacer(minLength: ZPDFSpacing.s)
                        Text(Self.imageStatus(isAccepted: image.isAccepted, canKeepPictures: canKeepPictures))
                            .zpdfText(.caption, .textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var defaultsSection: some View {
        section(.defaults, title: NSLocalizedString("Columns it fills in", comment: "Import review section")) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString(
                    "Tools in this set write a starting value into these Quantity Ledger columns. Nothing already measured is changed.",
                    comment: "Import review: explanation of custom column defaults"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(review.customDefaultKeys, id: \.self) { key in
                    Text(key).zpdfText(.code, .textPrimary)
                }
            }
        }
    }

    private var findingsSection: some View {
        section(.findings, title: NSLocalizedString("What Zenit noticed", comment: "Import review section")) {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                ForEach(review.findings) { finding in
                    HStack(alignment: .top, spacing: ZPDFSpacing.s) {
                        ZPDFGlyphView(finding.severity.displaySeverity.glyph, size: ZPDFSpacing.Control.iconSmall)
                            .foregroundStyle(ZPDFColor.color(finding.severity.displaySeverity.tint))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            if let presetName = finding.presetName {
                                Text(presetName).zpdfText(.caption.withWeight(.semibold), .textPrimary)
                            }
                            Text(finding.message)
                                .zpdfText(.caption, .textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(finding.accessibilityLabel))
                }
            }
        }
    }

    private func countRow(glyph: ZPDFGlyph, name: String, count: Int) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            ZPDFGlyphView(glyph, size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            Text(name).zpdfText(.control, .textPrimary)
            Spacer(minLength: ZPDFSpacing.s)
            Text(count.formatted()).zpdfText(.monoNumeric, .textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ id: Section,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFPanelHeader(
                title: title,
                isExpanded: Binding(
                    get: { expandedSection == id },
                    set: { expandedSection = $0 ? id : nil }
                )
            )
            if expandedSection == id {
                content()
                    .padding(.leading, ZPDFSpacing.l)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            if !review.isSafeToImport {
                ZPDFInlineWarning(
                    severity: .danger,
                    message: review.blockingFindings.first?.message
                        ?? NSLocalizedString(
                            "There is nothing in this file that Zenit can add.",
                            comment: "Import review: nothing importable"
                        )
                )
            }
            if Self.offersStrategy(review: review, canChoose: onImportWithStrategy != nil) {
                ZPDFInspectorRow(label: String(
                    format: NSLocalizedString(
                        "%d already in your library",
                        comment: "Tool set re-import: how many arriving tools are already in the library"
                    ),
                    review.libraryMatches.count
                )) {
                    Picker(selection: $strategy) {
                        ForEach(ToolSetImportStrategy.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    } label: {
                        Text(NSLocalizedString(
                            "Tools already in your library",
                            comment: "Label for the tool set re-import strategy picker"
                        ))
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Tools already in your library",
                        comment: "Label for the tool set re-import strategy picker"
                    )))
                }
            }
            HStack(spacing: ZPDFSpacing.s) {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Do Not Import", comment: "Cancel the tool set import"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(
                    Self.addToolsTitle(count: review.presets.count),
                    action: {
                        if let onImportWithStrategy {
                            onImportWithStrategy(strategy)
                        } else {
                            onImport()
                        }
                    }
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!review.isSafeToImport)
            }
        }
    }
}

extension ToolSetImportReviewSheet {
    /// The confirm button's title, "Add 1 Tool" / "Add 3 Tools". It used to be one
    /// `"Add %d Tools"` format for every count, so a one-tool set read "Add 1 Tools".
    static func addToolsTitle(count: Int, bundle: Bundle = .main) -> String {
        LocalizedPlural.string(
            "Add %lld Tools",
            count: count,
            one: NSLocalizedString(
                "Add %lld Tool",
                bundle: bundle,
                comment: "Confirm a tool set import of exactly one tool. %lld is the number of tools"
            ),
            other: NSLocalizedString(
                "Add %lld Tools",
                bundle: bundle,
                comment: "Confirm the tool set import. %lld is the number of tools"
            ),
            bundle: bundle
        )
    }
}
