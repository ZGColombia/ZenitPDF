import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// The export panel's accessory: pick the format, and optionally take the audit trail
/// along (ADR-0007 §3). Lives on the one existing export dialog rather than adding a
/// second menu entry — the trail is a companion of the takeoff, not a separate product.
@MainActor
final class ExportAccessoryView: NSView {

    /// The four formats the Quantity Ledger can leave in.
    ///
    /// All four are rendered from **one** ``ZPDFExport/ExportProjection``, which is where every
    /// unit conversion and every rounding happens exactly once. That is what makes the claim in
    /// the export gate true: the same takeoff exported four ways agrees digit for digit
    /// (QUALITY_BAR A29, A30).
    enum Format: Int, CaseIterable {
        case csv = 0
        case xlsx = 1
        case zenitJSON = 2
        case pdfReport = 3

        /// The extension the panel should offer, and the file that is actually written.
        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .xlsx: return "xlsx"
            case .zenitJSON: return "zpdfjson"
            case .pdfReport: return "pdf"
            }
        }

        var menuTitle: String {
            switch self {
            case .csv:
                return NSLocalizedString("CSV (ledger table)", comment: "Export format choice")
            case .xlsx:
                return NSLocalizedString("Excel workbook (.xlsx)", comment: "Export format choice")
            case .zenitJSON:
                return NSLocalizedString("Zenit JSON (.zpdfjson)", comment: "Export format choice")
            case .pdfReport:
                return NSLocalizedString("PDF report", comment: "Export format choice")
            }
        }

        /// The content type the save panel enforces.
        var contentType: UTType {
            switch self {
            case .csv: return .commaSeparatedText
            case .xlsx:
                return UTType(filenameExtension: "xlsx", conformingTo: .data)
                    ?? UTType.spreadsheet
            case .zenitJSON:
                // The declared identifier first: filename-extension lookup minted a
                // session-local dynamic type, and the import chooser filtering on that
                // could not select the file the export itself had written (LT-22).
                return UTType("com.zenitgroup.zenitpdf.ledger-json")
                    ?? UTType(filenameExtension: "zpdfjson", conformingTo: .json)
                    ?? .json
            case .pdfReport: return .pdf
            }
        }

        /// Whether the audit trail can ride inside this file.
        ///
        /// CSV takes it as a second labelled section and the PDF report as an appendix. XLSX and
        /// the interchange JSON have no such place today, so the checkbox is disabled rather than
        /// silently ignored — a ticked box that does nothing is a lie about what was exported.
        var carriesAuditTrail: Bool {
            switch self {
            case .csv, .pdfReport: return true
            case .xlsx, .zenitJSON: return false
            }
        }
    }

    /// Which rows leave (NL-QTY-14): the ledger as on screen, or only the selected rows.
    enum Scope: Int {
        case onScreen = 0
        case selected = 1
    }

    private weak var panel: NSSavePanel?
    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The row scope. "Selected rows" is offered only when rows are selected.
    let scopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// NL-QTY-11: saved export set-ups. The first item is "No template".
    let templatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// NL-QTY-11: the PDF report's page — size and orientation.
    let pageSizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// NL-QTY-11: the company block or footer line printed on every report page.
    let footerField = NSTextField(string: "")
    /// NL-QTY-11: the name a new template is saved under.
    let templateNameField = NSTextField(string: "")
    let saveTemplateButton = NSButton(title: "", target: nil, action: nil)
    /// Where templates are kept; `nil` in a process with no person (a test), which then offers none.
    private let templateStore: LedgerReportTemplateStore?
    /// The ledger's current request, captured into a template that is saved.
    private let captureRequest: (@MainActor () -> LedgerRequest)?
    /// The templates the popup lists, in order.
    private(set) var templates: [LedgerReportTemplate] = []

    /// The page sizes offered, in popup order.
    static let pageChoices: [(size: LedgerReportTemplate.PageSize, landscape: Bool)] = [
        (.a4, false), (.a4, true), (.a3, false), (.a3, true), (.letter, false), (.letter, true)
    ]
    private let trailCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString(
            "Include the audit trail (History)",
            comment: "Export accessory checkbox"
        ),
        target: nil,
        action: nil
    )

    /// What the export will contain, in one line (IM-187): all rows, or how many of how many
    /// because a filter is active.
    let scopeLabel = NSTextField(labelWithString: "")
    /// The workbook's options (IM-187), shown for the Excel format.
    let subtotalCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString("Subtotal rows", comment: "Export accessory checkbox: include subtotal rows"),
        target: nil, action: nil
    )
    let rawValuesCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString("Raw (unrounded) values", comment: "Export accessory checkbox: include raw value columns"),
        target: nil, action: nil
    )
    /// Feature 34: the workbook's totals as live
    /// `SUM` formulas over the rows, with the computed value cached, instead of typed numbers.
    let liveFormulasCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString(
            "Totals as live formulas",
            comment: "Export accessory checkbox: write workbook totals as spreadsheet formulas"
        ),
        target: nil, action: nil
    )
    /// Feature 16: each row's sheet, the scale it
    /// was measured at, its Scale Region, dates and author, as trace columns in every format.
    let traceCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString(
            "Include measurement trace (sheet, scale at measure time, dates, author)",
            comment: "Export accessory checkbox: append per-row provenance columns"
        ),
        target: nil, action: nil
    )

    // MARK: Round 2 (NL-QTY-09, -11, -13)

    /// NL-QTY-13: one workbook sheet per top-level group.
    let groupSheetsCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString("One sheet per group", comment: "Export accessory checkbox: a workbook sheet for each top-level group"),
        target: nil, action: nil
    )
    /// NL-QTY-09: the summary matrix — what runs down (first item: none) and across.
    let matrixRowsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let matrixColumnsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The groupings the matrix popups offer, in popup order.
    let matrixOptions: [(column: LedgerColumnID, title: String)]
    /// NL-QTY-11: the report cover's company block and logo, and the page-image appendix.
    let companyField = NSTextField(string: "")
    let logoButton = NSButton(title: "", target: nil, action: nil)
    let logoLabel = NSTextField(labelWithString: "")
    let pageImagesCheckbox = NSButton(
        checkboxWithTitle: NSLocalizedString("Append each sheet with its markups", comment: "Export accessory checkbox: page images after the PDF report"),
        target: nil, action: nil
    )
    /// The logo's bytes, chosen here or carried by a template.
    private(set) var logoData: Data?
    /// Chooses the logo file; injectable so a test decides the answer.
    var chooseLogoFile: (@MainActor (@escaping @MainActor (URL?) -> Void) -> Void)?
    private var matrixRow: NSStackView?
    private var reportExtrasRow: NSStackView?
    static let chooseLogoModalIdentifier = "export.chooseReportLogo"

    /// The summary matrix the controls ask for, or `nil` for none.
    var summaryAxes: (rows: LedgerColumnID, columns: LedgerColumnID)? {
        let down = matrixRowsPopUp.indexOfSelectedItem - 1
        let across = matrixColumnsPopUp.indexOfSelectedItem
        guard matrixOptions.indices.contains(down), matrixOptions.indices.contains(across), down != across,
              format == .xlsx || format == .pdfReport
        else { return nil }
        return (matrixOptions[down].column, matrixOptions[across].column)
    }

    /// The matrix choice whatever the format — what a template remembers.
    private var summaryAxesIgnoringFormat: (rows: LedgerColumnID, columns: LedgerColumnID)? {
        let down = matrixRowsPopUp.indexOfSelectedItem - 1
        let across = matrixColumnsPopUp.indexOfSelectedItem
        guard matrixOptions.indices.contains(down), matrixOptions.indices.contains(across), down != across else { return nil }
        return (matrixOptions[down].column, matrixOptions[across].column)
    }

    /// Whether the report ends with an image of every sheet.
    var includesPageImages: Bool { format == .pdfReport && pageImagesCheckbox.state == .on }

    /// Sets the logo, or clears it with `nil`.
    func setLogo(_ data: Data?) {
        logoData = data
        logoLabel.stringValue = data == nil
            ? NSLocalizedString("No logo", comment: "Export accessory: the report has no logo")
            : NSLocalizedString("Logo chosen", comment: "Export accessory: a report logo is set")
        logoButton.title = data == nil
            ? NSLocalizedString("Choose Logo…", comment: "Export accessory: pick a logo image for the report cover")
            : NSLocalizedString("Remove Logo", comment: "Export accessory: remove the report cover logo")
        logoButton.setAccessibilityLabel(logoButton.title)
    }

    @objc private func logoClicked() {
        if logoData != nil { setLogo(nil); return }
        let choose = chooseLogoFile ?? { deliver in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.message = NSLocalizedString("Choose a PNG or JPEG logo for the report cover.", comment: "Logo open panel message")
            ZenitModalPresenter.runOpenPanel(panel, identifier: Self.chooseLogoModalIdentifier, sheetedOn: nil) { answer in
                deliver(answer.firstURL)
            }
        }
        choose { [weak self] url in
            guard let self, let url else { return }
            guard let data = try? Data(contentsOf: url), PDFReportLogo.isReadable(data) else { NSSound.beep(); return }
            self.setLogo(data)
        }
    }

    /// Where the last chosen format is remembered. Injected, so a test never writes the
    /// person's own defaults.
    private let preferences: UserDefaults?
    static let formatPreferenceKey = "ZenitExportLedgerFormat"

    var format: Format {
        Format(rawValue: formatPopUp.indexOfSelectedItem) ?? .csv
    }

    var includesAuditTrail: Bool { format.carriesAuditTrail && trailCheckbox.state == .on }

    /// The chosen template, or `nil` for none.
    var selectedTemplate: LedgerReportTemplate? {
        let index = templatePopUp.indexOfSelectedItem - 1
        return templates.indices.contains(index) ? templates[index] : nil
    }

    /// The PDF report's options the controls stand for.
    var pdfOptions: PDFReportOptions {
        let choice = Self.pageChoices[max(0, min(Self.pageChoices.count - 1, pageSizePopUp.indexOfSelectedItem))]
        let base: PDFReportPageSize = switch choice.size {
        case .a4: .a4
        case .a3: PDFReportPageSize(width: 841.89, height: 1190.551)
        case .letter: .usLetter
        }
        let footer = footerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = PDFReportOptions(
            pageSize: choice.landscape ? base.landscape : base.portrait,
            includeCoverPage: selectedTemplate?.includeCoverPage ?? true,
            includeGroupHeadings: selectedTemplate?.includeGroupHeadings ?? true,
            includeGroupSubtotals: selectedTemplate?.includeGroupSubtotals ?? true,
            footerNote: footer.isEmpty ? nil : footer
        )
        options.logoImageData = logoData
        let company = companyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        options.companyBlock = company.isEmpty ? nil : company
        return options
    }

    /// The chosen row scope.
    var scope: Scope {
        Scope(rawValue: scopePopUp.indexOfSelectedItem) ?? .onScreen
    }

    /// Whether the rows carry their measurement trace. Every format can write it.
    var includesMeasurementTrace: Bool { traceCheckbox.state == .on }

    /// The workbook options the checkboxes stand for.
    var xlsxOptions: XLSXExportOptions {
        var options = XLSXExportOptions()
        options.includeSubtotalRows = subtotalCheckbox.state == .on
        options.includeRawColumns = rawValuesCheckbox.state == .on
        options.includeFormulas = liveFormulasCheckbox.state == .on
        options.includeGroupSheets = groupSheetsCheckbox.state == .on
        return options
    }

    /// The scope line for a ledger of `rowCount` rows out of `totalRows`.
    static func scopeText(rowCount: Int, totalRows: Int, isFiltered: Bool) -> String {
        if isFiltered {
            return String(
                format: NSLocalizedString(
                    "Exports %1$d of %2$d rows — a filter is active",
                    comment: "Export accessory scope line when the ledger is filtered"
                ),
                rowCount, totalRows
            )
        }
        return String(
            format: NSLocalizedString("Exports all %d rows", comment: "Export accessory scope line"),
            rowCount
        )
    }

    init(
        panel: NSSavePanel,
        scope: String? = nil,
        preferences: UserDefaults? = nil,
        selectedRowCount: Int = 0,
        templateStore: LedgerReportTemplateStore? = nil,
        captureRequest: (@MainActor () -> LedgerRequest)? = nil,
        matrixOptions: [(column: LedgerColumnID, title: String)] = []
    ) {
        self.matrixOptions = matrixOptions
        self.panel = panel
        self.preferences = preferences
        self.templateStore = templateStore
        self.captureRequest = captureRequest
        super.init(frame: .zero)

        pageSizePopUp.addItems(withTitles: [
            NSLocalizedString("A4 portrait", comment: "Export accessory page size"),
            NSLocalizedString("A4 landscape", comment: "Export accessory page size"),
            NSLocalizedString("A3 portrait", comment: "Export accessory page size"),
            NSLocalizedString("A3 landscape", comment: "Export accessory page size"),
            NSLocalizedString("Letter portrait", comment: "Export accessory page size"),
            NSLocalizedString("Letter landscape", comment: "Export accessory page size")
        ])
        pageSizePopUp.setAccessibilityLabel(NSLocalizedString("Report page size", comment: "Accessibility label for the report page size popup"))
        footerField.placeholderString = NSLocalizedString("Company block or footer line", comment: "Export accessory: footer field placeholder")
        footerField.setAccessibilityLabel(NSLocalizedString("Report footer", comment: "Accessibility label for the report footer field"))
        templatePopUp.target = self
        templatePopUp.action = #selector(templateChanged)
        templatePopUp.setAccessibilityLabel(NSLocalizedString("Export template", comment: "Accessibility label for the export template popup"))
        templateNameField.placeholderString = NSLocalizedString("Template name", comment: "Export accessory: template name placeholder")
        templateNameField.setAccessibilityLabel(NSLocalizedString("Template name", comment: "Export accessory: template name placeholder"))
        saveTemplateButton.title = NSLocalizedString("Save as Template", comment: "Export accessory: save the current settings as a template")
        saveTemplateButton.bezelStyle = .rounded
        saveTemplateButton.target = self
        saveTemplateButton.action = #selector(saveTemplateClicked)
        matrixRowsPopUp.addItem(withTitle: NSLocalizedString("No summary matrix", comment: "Export accessory: no summary matrix"))
        matrixRowsPopUp.addItems(withTitles: matrixOptions.map(\.title))
        matrixColumnsPopUp.addItems(withTitles: matrixOptions.map(\.title))
        matrixColumnsPopUp.selectItem(at: min(1, max(0, matrixOptions.count - 1)))
        matrixRowsPopUp.setAccessibilityLabel(NSLocalizedString("Summary matrix rows", comment: "Accessibility label: the grouping down the summary matrix"))
        matrixColumnsPopUp.setAccessibilityLabel(NSLocalizedString("Summary matrix columns", comment: "Accessibility label: the grouping across the summary matrix"))
        groupSheetsCheckbox.setAccessibilityLabel(groupSheetsCheckbox.title)
        pageImagesCheckbox.setAccessibilityLabel(pageImagesCheckbox.title)
        companyField.placeholderString = NSLocalizedString("Company block (cover)", comment: "Export accessory: company block placeholder")
        companyField.setAccessibilityLabel(NSLocalizedString("Company block", comment: "Accessibility label for the report company block field"))
        companyField.usesSingleLineMode = false
        logoButton.bezelStyle = .rounded
        logoButton.target = self
        logoButton.action = #selector(logoClicked)
        logoLabel.textColor = .secondaryLabelColor
        setLogo(nil)
        reloadTemplates(selecting: nil)

        scopePopUp.addItems(withTitles: [
            NSLocalizedString("Rows as on screen", comment: "Export accessory scope choice: every row the ledger shows"),
            String(
                format: NSLocalizedString("Selected rows (%d)", comment: "Export accessory scope choice: only the selected rows; the count"),
                selectedRowCount
            )
        ])
        scopePopUp.autoenablesItems = false
        scopePopUp.item(at: Scope.selected.rawValue)?.isEnabled = selectedRowCount > 0
        scopePopUp.setAccessibilityLabel(NSLocalizedString("Rows to export", comment: "Accessibility label for the export scope popup"))

        formatPopUp.addItems(withTitles: Format.allCases.map(\.menuTitle))
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)
        formatPopUp.setAccessibilityLabel(NSLocalizedString("Export format", comment: "Accessibility label for the export format popup"))
        // The format chosen last time (IM-185).
        if let preferences, preferences.object(forKey: Self.formatPreferenceKey) != nil,
           let remembered = Format(rawValue: preferences.integer(forKey: Self.formatPreferenceKey)) {
            formatPopUp.selectItem(at: remembered.rawValue)
        }
        let defaults = XLSXExportOptions()
        subtotalCheckbox.state = defaults.includeSubtotalRows ? .on : .off
        rawValuesCheckbox.state = defaults.includeRawColumns ? .on : .off
        liveFormulasCheckbox.state = defaults.includeFormulas ? .on : .off
        traceCheckbox.state = .off
        liveFormulasCheckbox.setAccessibilityLabel(liveFormulasCheckbox.title)
        traceCheckbox.setAccessibilityLabel(traceCheckbox.title)
        scopeLabel.stringValue = scope ?? ""
        scopeLabel.isHidden = scope == nil
        scopeLabel.textColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: NSLocalizedString(
            "Format:", comment: "Export accessory format label"
        ))
        let row = NSStackView(views: [label, formatPopUp])
        row.orientation = .horizontal
        row.spacing = 8
        let scopeRow = NSStackView(views: [
            NSTextField(labelWithString: NSLocalizedString("Rows:", comment: "Export accessory scope label")),
            scopePopUp
        ])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8
        let templateRow = NSStackView(views: [
            NSTextField(labelWithString: NSLocalizedString("Template:", comment: "Export accessory template label")),
            templatePopUp, templateNameField, saveTemplateButton
        ])
        templateRow.orientation = .horizontal
        templateRow.spacing = 8
        templateRow.isHidden = templateStore == nil
        let pageRow = NSStackView(views: [pageSizePopUp, footerField])
        pageRow.orientation = .horizontal
        pageRow.spacing = 8
        self.pageRow = pageRow
        let matrixRow = NSStackView(views: [
            NSTextField(labelWithString: NSLocalizedString("Summary:", comment: "Export accessory summary matrix label")),
            matrixRowsPopUp,
            NSTextField(labelWithString: NSLocalizedString("by", comment: "Export accessory: summary matrix rows by columns")),
            matrixColumnsPopUp
        ])
        matrixRow.orientation = .horizontal
        matrixRow.spacing = 8
        matrixRow.isHidden = matrixOptions.count < 2
        self.matrixRow = matrixRow
        let reportExtrasRow = NSStackView(views: [companyField, logoButton, logoLabel])
        reportExtrasRow.orientation = .horizontal
        reportExtrasRow.spacing = 8
        self.reportExtrasRow = reportExtrasRow

        let stack = NSStackView(views: [
            scopeLabel, templateRow, row, scopeRow, trailCheckbox, traceCheckbox, subtotalCheckbox, rawValuesCheckbox,
            liveFormulasCheckbox, groupSheetsCheckbox, matrixRow, pageRow, reportExtrasRow, pageImagesCheckbox
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func formatChanged() { applyFormat() }

    /// The page-size and footer row, shown for the PDF report only.
    private var pageRow: NSStackView?

    // MARK: Templates (NL-QTY-11)

    private func reloadTemplates(selecting id: UUID?) {
        templates = (try? templateStore?.read()) ?? []
        templatePopUp.removeAllItems()
        templatePopUp.addItem(withTitle: NSLocalizedString("No template", comment: "Export accessory: no template chosen"))
        templatePopUp.addItems(withTitles: templates.map(\.name))
        if let id, let index = templates.firstIndex(where: { $0.id == id }) {
            templatePopUp.selectItem(at: index + 1)
        }
    }

    @objc private func templateChanged() {
        guard let template = selectedTemplate else { return }
        apply(template)
    }

    /// Sets every control to what a template says.
    func apply(_ template: LedgerReportTemplate) {
        let format: Format = switch template.format {
        case .csv: .csv
        case .xlsx: .xlsx
        case .zenitJSON: .zenitJSON
        case .pdfReport: .pdfReport
        }
        formatPopUp.selectItem(at: format.rawValue)
        trailCheckbox.state = template.includeAuditTrail ? .on : .off
        traceCheckbox.state = template.includeMeasurementTrace ? .on : .off
        subtotalCheckbox.state = template.workbookSubtotalRows ? .on : .off
        rawValuesCheckbox.state = template.workbookRawColumns ? .on : .off
        liveFormulasCheckbox.state = template.workbookLiveFormulas ? .on : .off
        if let index = Self.pageChoices.firstIndex(where: { $0.size == template.pageSize && $0.landscape == template.landscape }) {
            pageSizePopUp.selectItem(at: index)
        }
        footerField.stringValue = template.footerNote
        companyField.stringValue = template.companyBlock
        groupSheetsCheckbox.state = template.workbookGroupSheets ? .on : .off
        pageImagesCheckbox.state = template.includePageImages ? .on : .off
        setLogo(template.logoDigest.flatMap { templateStore?.logo(digest: $0) })
        if let axes = template.matrixAxes,
           let down = matrixOptions.firstIndex(where: { $0.column == axes.rows }),
           let across = matrixOptions.firstIndex(where: { $0.column == axes.columns }) {
            matrixRowsPopUp.selectItem(at: down + 1)
            matrixColumnsPopUp.selectItem(at: across)
        } else {
            matrixRowsPopUp.selectItem(at: 0)
        }
        applyFormat()
    }

    /// The template the controls stand for now, capturing the ledger's current view.
    func currentTemplate(named name: String) -> LedgerReportTemplate {
        let format: LedgerReportTemplate.Format = switch self.format {
        case .csv: .csv
        case .xlsx: .xlsx
        case .zenitJSON: .zenitJSON
        case .pdfReport: .pdfReport
        }
        var template = captureRequest.map { LedgerReportTemplate.capturing($0(), name: name, format: format) }
            ?? LedgerReportTemplate(name: name, format: format)
        let page = Self.pageChoices[max(0, min(Self.pageChoices.count - 1, pageSizePopUp.indexOfSelectedItem))]
        template.pageSize = page.size
        template.landscape = page.landscape
        template.footerNote = footerField.stringValue
        template.includeAuditTrail = trailCheckbox.state == .on
        template.includeMeasurementTrace = traceCheckbox.state == .on
        template.workbookSubtotalRows = subtotalCheckbox.state == .on
        template.workbookRawColumns = rawValuesCheckbox.state == .on
        template.workbookLiveFormulas = liveFormulasCheckbox.state == .on
        template.workbookGroupSheets = groupSheetsCheckbox.state == .on
        template.includePageImages = pageImagesCheckbox.state == .on
        template.companyBlock = companyField.stringValue
        template.logoDigest = logoData.flatMap { try? templateStore?.saveLogo($0) }
        if let axes = summaryAxesIgnoringFormat {
            template.matrixRows = axes.rows.rawValue
            template.matrixColumns = axes.columns.rawValue
        }
        return template
    }

    @objc private func saveTemplateClicked() {
        let name = templateNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let templateStore else { NSSound.beep(); return }
        let template = currentTemplate(named: name)
        do {
            try templateStore.save(template)
            reloadTemplates(selecting: nil)
            if let index = templates.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                templatePopUp.selectItem(at: index + 1)
            }
            templateNameField.stringValue = ""
        } catch {
            NSSound.beep()
        }
    }

    /// A file name with its extension switched to `format`'s — replacing only an extension
    /// this dialog writes. A name like "Level 2.1" has no extension to replace: stripping
    /// ".1" turned it into "Level 2.xlsx" (BH-913).
    static func renamed(_ name: String, to format: Format) -> String {
        let known = Set(Format.allCases.map(\.fileExtension))
        let current = (name as NSString).pathExtension.lowercased()
        let base = known.contains(current) ? (name as NSString).deletingPathExtension : name
        return base + "." + format.fileExtension
    }

    /// Chooses a format the way the pop-up does, so the panel wiring is testable without a
    /// click. The whole point of the accessory is what it does to the save panel, and that is
    /// unobservable from the enum alone.
    func selectForTesting(_ format: Format) {
        formatPopUp.selectItem(at: format.rawValue)
        applyFormat()
    }

    /// Keeps the panel's content type in step with the chosen format, so the extension
    /// the user sees is the file that gets written.
    func applyFormat() {
        let chosen = format
        panel?.allowedContentTypes = [chosen.contentType]
        // The extension the panel shows must be the extension the writer uses; an XLSX written
        // to a file called `.csv` is a file Excel refuses and a user cannot explain.
        if let panel, !panel.nameFieldStringValue.isEmpty {
            panel.nameFieldStringValue = Self.renamed(panel.nameFieldStringValue, to: chosen)
        }
        preferences?.set(chosen.rawValue, forKey: Self.formatPreferenceKey)
        let workbook = chosen == .xlsx
        subtotalCheckbox.isHidden = !workbook
        rawValuesCheckbox.isHidden = !workbook
        liveFormulasCheckbox.isHidden = !workbook
        groupSheetsCheckbox.isHidden = !workbook
        matrixRow?.isHidden = matrixOptions.count < 2 || !(workbook || chosen == .pdfReport)
        reportExtrasRow?.isHidden = chosen != .pdfReport
        pageImagesCheckbox.isHidden = chosen != .pdfReport
        pageRow?.isHidden = chosen != .pdfReport
        trailCheckbox.isEnabled = chosen.carriesAuditTrail
        trailCheckbox.toolTip = chosen.carriesAuditTrail
            ? nil
            : NSLocalizedString(
                "This format carries the ledger only. Export CSV or the PDF report to take the audit trail with it.",
                comment: "Why the audit-trail checkbox is unavailable for a format"
            )
    }
}
