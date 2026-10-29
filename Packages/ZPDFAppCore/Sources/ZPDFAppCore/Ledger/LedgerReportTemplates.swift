import CryptoKit
import Foundation
import ZPDFUIPresentation

/// A saved export set-up (NL-QTY-11): format, which rows and how grouped, and how the PDF report
/// looks — applied again to any project in one choice. Never a scale, never numbers.
public struct LedgerReportTemplate: Codable, Hashable, Sendable, Identifiable {

    public enum Format: String, Codable, Hashable, Sendable, CaseIterable {
        case csv, xlsx, zenitJSON, pdfReport
    }

    public enum PageSize: String, Codable, Hashable, Sendable, CaseIterable {
        case a4, a3, letter
    }

    public var id: UUID
    public var name: String
    public var format: Format
    /// When true, the export takes the ledger exactly as it is on screen and the view fields
    /// below are ignored. When false, they replace the on-screen grouping, filter and columns.
    public var usesOnScreenView: Bool
    public var grouping: [String]
    public var filter: LedgerFilterGroup?
    public var columns: [String]
    // PDF report
    public var pageSize: PageSize
    public var landscape: Bool
    public var includeCoverPage: Bool
    public var includeGroupHeadings: Bool
    public var includeGroupSubtotals: Bool
    /// The company block or footer line printed on every page.
    public var footerNote: String
    // Companions
    public var includeAuditTrail: Bool
    public var includeMeasurementTrace: Bool
    // Workbook
    public var workbookSubtotalRows: Bool
    public var workbookRawColumns: Bool
    public var workbookLiveFormulas: Bool
    // Round 2 (NL-QTY-09, -11, -13). Every one is optional in the file: a template saved before
    // these existed reads back with each at its default.
    /// The company block printed on the report cover, one line per line.
    public var companyBlock: String = ""
    /// The cover logo, by the SHA-256 digest of its bytes in the store's `Logos` folder — kept
    /// like stamp artwork, so two templates with one logo keep one file.
    public var logoDigest: String?
    /// Append each sheet, with its markups, as a page image after the report.
    public var includePageImages: Bool = false
    /// The summary matrix (NL-QTY-09): the grouping down and across, both or neither.
    public var matrixRows: String?
    public var matrixColumns: String?
    /// One workbook sheet per top-level group (NL-QTY-13).
    public var workbookGroupSheets: Bool = false

    /// The matrix axes, when both are set and differ.
    public var matrixAxes: (rows: LedgerColumnID, columns: LedgerColumnID)? {
        guard let matrixRows, let matrixColumns, !matrixRows.isEmpty, matrixRows != matrixColumns else { return nil }
        return (LedgerColumnID(matrixRows), LedgerColumnID(matrixColumns))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        format = try container.decode(Format.self, forKey: .format)
        usesOnScreenView = try container.decode(Bool.self, forKey: .usesOnScreenView)
        grouping = try container.decode([String].self, forKey: .grouping)
        filter = try container.decodeIfPresent(LedgerFilterGroup.self, forKey: .filter)
        columns = try container.decode([String].self, forKey: .columns)
        pageSize = try container.decode(PageSize.self, forKey: .pageSize)
        landscape = try container.decode(Bool.self, forKey: .landscape)
        includeCoverPage = try container.decode(Bool.self, forKey: .includeCoverPage)
        includeGroupHeadings = try container.decode(Bool.self, forKey: .includeGroupHeadings)
        includeGroupSubtotals = try container.decode(Bool.self, forKey: .includeGroupSubtotals)
        footerNote = try container.decode(String.self, forKey: .footerNote)
        includeAuditTrail = try container.decode(Bool.self, forKey: .includeAuditTrail)
        includeMeasurementTrace = try container.decode(Bool.self, forKey: .includeMeasurementTrace)
        workbookSubtotalRows = try container.decode(Bool.self, forKey: .workbookSubtotalRows)
        workbookRawColumns = try container.decode(Bool.self, forKey: .workbookRawColumns)
        workbookLiveFormulas = try container.decode(Bool.self, forKey: .workbookLiveFormulas)
        companyBlock = try container.decodeIfPresent(String.self, forKey: .companyBlock) ?? ""
        logoDigest = try container.decodeIfPresent(String.self, forKey: .logoDigest)
        includePageImages = try container.decodeIfPresent(Bool.self, forKey: .includePageImages) ?? false
        matrixRows = try container.decodeIfPresent(String.self, forKey: .matrixRows)
        matrixColumns = try container.decodeIfPresent(String.self, forKey: .matrixColumns)
        workbookGroupSheets = try container.decodeIfPresent(Bool.self, forKey: .workbookGroupSheets) ?? false
    }

    public init(
        id: UUID = UUID(), name: String, format: Format, usesOnScreenView: Bool = true,
        grouping: [String] = [], filter: LedgerFilterGroup? = nil, columns: [String] = [],
        pageSize: PageSize = .a4, landscape: Bool = false, includeCoverPage: Bool = true,
        includeGroupHeadings: Bool = true, includeGroupSubtotals: Bool = true, footerNote: String = "",
        includeAuditTrail: Bool = false, includeMeasurementTrace: Bool = false,
        workbookSubtotalRows: Bool = true, workbookRawColumns: Bool = false, workbookLiveFormulas: Bool = false
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.usesOnScreenView = usesOnScreenView
        self.grouping = grouping
        self.filter = filter
        self.columns = columns
        self.pageSize = pageSize
        self.landscape = landscape
        self.includeCoverPage = includeCoverPage
        self.includeGroupHeadings = includeGroupHeadings
        self.includeGroupSubtotals = includeGroupSubtotals
        self.footerNote = footerNote
        self.includeAuditTrail = includeAuditTrail
        self.includeMeasurementTrace = includeMeasurementTrace
        self.workbookSubtotalRows = workbookSubtotalRows
        self.workbookRawColumns = workbookRawColumns
        self.workbookLiveFormulas = workbookLiveFormulas
    }

    /// The ledger request an export with this template is built from. A column or grouping key
    /// the target project does not have is left for the ledger to report as unapplied — never
    /// silently dropped.
    public func request(onScreen: LedgerRequest) -> LedgerRequest {
        guard !usesOnScreenView else { return onScreen }
        var request = onScreen
        request.grouping = grouping.map { LedgerColumnID($0) }
        request.filter = filter ?? LedgerFilterGroup(id: UUID())
        request.visibleColumns = columns.map { LedgerColumnID($0) }
        return request
    }

    /// A template that captures the ledger as it is now: its grouping, filter and columns.
    public static func capturing(_ request: LedgerRequest, name: String, format: Format) -> LedgerReportTemplate {
        LedgerReportTemplate(
            name: name, format: format, usesOnScreenView: false,
            grouping: request.grouping.map(\.rawValue),
            filter: request.filter.isEmpty ? nil : request.filter,
            columns: request.visibleColumns.map(\.rawValue)
        )
    }
}

/// The saved templates, as a file in Application Support — shared by copying the file, like a
/// tool set (NL-QTY-11).
public struct LedgerReportTemplateStore: Sendable {

    public static let formatIdentifier = "zenit.reportTemplates"
    public static let currentSchemaVersion = 1

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("report-templates.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Zenit PDF/ReportTemplates`.
    public static func standard() -> LedgerReportTemplateStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return LedgerReportTemplateStore(directory: base
            .appendingPathComponent("Zenit PDF", isDirectory: true)
            .appendingPathComponent("ReportTemplates", isDirectory: true))
    }

    struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var templates: [LedgerReportTemplate]
    }

    /// The templates, `[]` when none were saved; an unreadable file is an error, never empty.
    public func read() throws -> [LedgerReportTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.format == Self.formatIdentifier, envelope.schemaVersion == Self.currentSchemaVersion else {
            throw DocumentCommandError.ledgerFailed("not a template file this version can read")
        }
        return envelope.templates
    }

    /// Saves a template; one with the same name is replaced.
    public func save(_ template: LedgerReportTemplate) throws {
        var templates = try read()
        if let index = templates.firstIndex(where: { $0.name.lowercased() == template.name.lowercased() }) {
            var replaced = template
            replaced.id = templates[index].id
            templates[index] = replaced
        } else {
            templates.append(template)
        }
        try write(templates)
    }

    /// Where logos are kept, one file per digest.
    public var logoDirectory: URL { directory.appendingPathComponent("Logos", isDirectory: true) }

    /// The hex SHA-256 of `data`.
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores logo bytes by digest and returns the digest; the same bytes twice keep one file.
    public func saveLogo(_ data: Data) throws -> String {
        let digest = Self.digest(data)
        let url = logoDirectory.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: logoDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return digest
    }

    /// The logo bytes for a digest, or `nil` when the file is gone or no longer matches.
    public func logo(digest: String) -> Data? {
        guard digest.allSatisfy({ $0.isHexDigit }), digest.count == 64,
              let data = try? Data(contentsOf: logoDirectory.appendingPathComponent(digest)),
              Self.digest(data) == digest
        else { return nil }
        return data
    }

    /// Removes a template.
    public func remove(id: UUID) throws {
        try write(try read().filter { $0.id != id })
    }

    func write(_ templates: [LedgerReportTemplate]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(Envelope(format: Self.formatIdentifier, schemaVersion: Self.currentSchemaVersion, templates: templates))
            .write(to: fileURL, options: .atomic)
    }
}
