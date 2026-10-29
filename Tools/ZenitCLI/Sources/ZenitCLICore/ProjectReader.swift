import CoreGraphics
import Foundation
import GRDB
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence

/// Loads a `.zpdfproj` read-only into a headless takeoff session — the same session, ledger and
/// report code the app runs — and answers the CLI's questions from it.
public struct ProjectReader: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case notAProject(String)
        case noDrawing(String)
        case noSavedTakeoff(String)
        /// The project fails `zenit verify`: its numbers are not reported (U-101).
        case unverified(path: String, problems: [String])
        /// A drawing row names a file outside the package's `documents/` folder.
        case drawingOutsidePackage(String)

        public var description: String {
            switch self {
            case let .notAProject(path): return "\(path) is not a Zenit PDF project (.zpdfproj)."
            case let .noDrawing(path): return "\(path) holds no readable drawing."
            case let .noSavedTakeoff(path): return "\(path) has no saved takeoff yet."
            case let .unverified(path, problems):
                return (["\(path) fails verification, so its numbers are not reported. "
                         + "Pass --allow-unverified to read them anyway."] + problems.map { "  \($0)" })
                    .joined(separator: "\n")
            case let .drawingOutsidePackage(relativePath):
                return "a drawing of the project points outside its documents folder (\(relativePath)); it is not read."
            }
        }
    }

    public let url: URL
    /// Report a project that fails verification anyway, with its problems attached to the
    /// result (`--allow-unverified`). Off by default: the application refuses such a project.
    public let allowUnverified: Bool
    public init(url: URL, allowUnverified: Bool = false) {
        self.url = url
        self.allowUnverified = allowUnverified
    }

    /// Everything the commands need, loaded once.
    public struct Loaded: Sendable {
        public let session: TakeoffSession
        public let projectName: String
        public let pageCount: Int
        public let markupCount: Int
        public let unreadableMarkupCount: Int
        public let scaleCount: Int
        /// The drawings of the project (R-189): one, or every drawing of a set.
        public let drawingCount: Int
        /// What `zenit verify` would report; empty for a sound project. Only ever non-empty
        /// when the reader was asked to ``allowUnverified``.
        public let verificationProblems: [String]
    }

    /// Top-level package members the snapshot leaves out (T-088): the two saved-version slots,
    /// each a whole clone of the package, and the pictures the app draws after a save. Neither the
    /// read-only open, the recovery assessment nor the takeoff loader reads them. A list of what
    /// to leave out rather than of what to keep, so a member the loader or the integrity check
    /// needs — the manifest, the integrity record, the database with its `-wal` and `-shm`,
    /// `documents/`, `recovery/` — can never be left behind by an omission here.
    public static let snapshotExclusions: [String] = [
        ProjectPackageLayout.versions, ProjectPackageLayout.thumbnails, ProjectPackageLayout.finderQuickLook
    ]

    /// Runs `body` over a private copy of the package, deleted afterwards.
    ///
    /// Opening a project's SQLite database — even read-only — touches its `-shm` index file, so a
    /// read-only open is not a byte-for-byte promise. The CLI reads a copy instead, and the
    /// package a person or the application is working in is never touched by a single byte.
    ///
    /// The copy is an APFS clone — no space and no time — only on the volume the project is on;
    /// the temporary directory is on the boot volume, so a project on an external disk or a share
    /// is copied for real. It used to be copied whole, both saved-version slots included: about
    /// three times the project for every `zenit` run (T-088). The members in
    /// ``snapshotExclusions`` stay behind, as empty directories so the copy has the shape a
    /// package has.
    public static func withSnapshot<T>(of url: URL, _ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        for member in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            if snapshotExclusions.contains(member) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(member).path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    try FileManager.default.createDirectory(at: copy.appendingPathComponent(member, isDirectory: true),
                                                            withIntermediateDirectories: false)
                }
            } else {
                try FileManager.default.copyItem(at: url.appendingPathComponent(member), to: copy.appendingPathComponent(member))
            }
        }
        return try await body(copy)
    }

    public func load() async throws -> Loaded {
        guard url.pathExtension.lowercased() == ProjectPackageLayout.fileExtension else { throw Failure.notAProject(url.path) }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(ProjectPackageLayout.manifest).path) else {
            throw Failure.notAProject(url.path)
        }
        return try await Self.withSnapshot(of: url) { try await load(copy: $0) }
    }

    private func load(copy: URL) async throws -> Loaded {
        // Read-only: nothing is written, not even the crash marker, and an interrupted session
        // elsewhere is read as it was last committed rather than "recovered". A project last
        // written by an older build is read through a migrated private copy of its database
        // (R-197, in the package's own read-only open), so its companion tables exist.
        //
        // Verified first, the way `zenit verify` and the application's open path judge it
        // (U-101). The read-only open records the integrity verdict and the schema deviations
        // without enforcing either, so `totals`, `export` and `info` used to print the numbers of
        // a project whose drawing or database had been changed outside Zenit PDF — exit 0, no
        // word — while `verify` on the same file exited 1.
        let assessment = try await ProjectPackage.assessRecovery(at: copy)
        let package = try await ProjectPackage.open(at: copy, resolving: .openReadOnly)
        let verification: Verification
        do { verification = try await Self.verification(of: package, assessment: assessment) } catch {
            try? await package.close()
            throw error
        }
        guard verification.isSound || allowUnverified else {
            try? await package.close()
            throw Failure.unverified(path: url.path, problems: verification.problems)
        }
        let rows: [TakeoffArchive.DrawingRow]
        let stored: [(documentId: String, takeoff: TakeoffArchive.StoredTakeoff?)]
        let labels: [String: [Int: String]]
        let name: String
        do {
            // Every drawing of the project (R-189), the way the application's load pipeline
            // reads a set: each document row's takeoff, adopted as one. `TakeoffArchive.read`
            // alone is the primary drawing, and the CLI used to report its quantities as the
            // project's totals with no word about the others.
            rows = try await TakeoffArchive.drawingRows(of: package)
            stored = try await TakeoffArchive.readSet(from: package)
            labels = try await Self.storedPageLabels(of: package)
            name = await package.manifest.displayName
        } catch {
            try? await package.close()
            throw error
        }
        try? await package.close()
        guard stored.contains(where: { $0.takeoff != nil }) else {
            throw Failure.noSavedTakeoff(url.path)
        }

        var drawings: [(documentId: String, pages: [ZPDFContracts.PageDescriptor])] = []
        var sessionDocumentID: DocumentID?
        for row in rows {
            // The primary drawing is read through the package's working copy, like the app.
            let member = try Self.drawingMember(relativePath: row.relativePath, isPrimary: row.isPrimary)
            let documentID = DocumentID(UUID())
            if row.isPrimary || sessionDocumentID == nil { sessionDocumentID = documentID }
            drawings.append((row.id, try Self.pages(of: copy.appendingPathComponent(member), documentID: documentID,
                                                    labels: labels[row.id] ?? [:])))
        }
        guard let sessionDocumentID else { throw Failure.noDrawing(url.path) }
        let adopted = TakeoffArchive.adoptingStoredSet(drawings, stored: stored)
        guard let takeoff = adopted.takeoff else { throw Failure.noSavedTakeoff(url.path) }

        // The session as the application builds it for a saved takeoff: its display units, its
        // columns and layers, the hydration, then the named sheets and the arrangement.
        let session = try TakeoffSession(
            documentID: sessionDocumentID, pages: adopted.pages, units: takeoff.displayUnits ?? .metric
        )
        _ = await session.restoreCustomColumns(takeoff.customColumns)
        await session.restoreMarkupLayers(takeoff.markupLayers, active: takeoff.activeMarkupLayerID)
        try await session.hydrate(markups: takeoff.markups, scales: takeoff.scales, pageScaleIDs: takeoff.pageScaleIDs,
                                  calibrationEvidence: takeoff.calibrationEvidence,
                                  scaleRegions: takeoff.scaleRegions, projectZones: takeoff.projectZones)
        if !takeoff.sheetIdentities.isEmpty { await session.restoreSheetIdentities(takeoff.sheetIdentities) }
        if !takeoff.excludedPageIDs.isEmpty || !takeoff.pageViews.isEmpty {
            await session.restoreArrangement(excluded: takeoff.excludedPageIDs, views: takeoff.pageViews)
        }
        return Loaded(session: session, projectName: name, pageCount: adopted.pages.count, markupCount: takeoff.markups.count,
                      unreadableMarkupCount: takeoff.unreadableMarkupIDs.count, scaleCount: takeoff.scales.count,
                      drawingCount: drawings.count, verificationProblems: verification.isSound ? [] : verification.problems)
    }

    /// The package member a drawing row is read from: the working copy for the primary drawing,
    /// otherwise the row's own path — which must lie inside `documents/`, by the rule the
    /// package's drawing-set integrity check applies. A row naming `../…` or an absolute path is
    /// refused rather than followed out of the package, even under `--allow-unverified`.
    static func drawingMember(relativePath: String, isPrimary: Bool) throws -> String {
        if isPrimary { return ProjectPackageLayout.workingPDF }
        guard relativePath.hasPrefix("\(ProjectPackageLayout.documents)/"), !relativePath.contains("..") else {
            throw Failure.drawingOutsidePackage(relativePath)
        }
        return relativePath
    }

    /// One drawing's pages, read with CoreGraphics; fresh ids, which the stored ones replace.
    ///
    /// W-093: each page carries the label and the `/UserUnit` the application's pages carry.
    /// Every page used to be labelled "1…n" with a user unit of 1, so on a labelled set the
    /// export's Page column read "1" where the application's read "A-101", and on a
    /// `/UserUnit 2` sheet a 1:100 preset was printed as "1:200" in the Scale cell and header
    /// (the CR-128 conversion divides the user unit back out, and had none to divide by).
    ///
    /// - Parameter labels: the drawing's saved page labels by page index
    ///   (``storedPageLabels(of:)``); a page without one is labelled by its number, as the
    ///   application labels a page its drawing gives no label.
    static func pages(
        of drawingURL: URL, documentID: DocumentID, labels: [Int: String] = [:]
    ) throws -> [ZPDFContracts.PageDescriptor] {
        guard let document = CGPDFDocument(drawingURL as CFURL), document.numberOfPages > 0 else {
            throw Failure.noDrawing(drawingURL.path)
        }
        // The application's own read and rule (X-051): one implementation in ZPDFAppCore.
        let userUnits = PageUserUnits.read(from: document)
        var pages: [ZPDFContracts.PageDescriptor] = []
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { continue }
            let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
            pages.append(ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: number - 1,
                label: labels[number - 1] ?? String(number),
                boxes: PageBoxes(
                    media: PDFRect(x: media.minX, y: media.minY, width: media.width, height: media.height),
                    crop: PDFRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)),
                rotation: try PageRotation.normalizing(degrees: Int(page.rotationAngle) / 90 * 90),
                userUnit: userUnits[number - 1] ?? 1
            ))
        }
        return pages
    }

    /// The printed label of every saved page, keyed by document row and page index (W-093).
    ///
    /// The application labels its pages from the drawing's `/PageLabels` when it opens it, and
    /// the save writes each label into the page row (`page.page_label`); the integrity check
    /// has already proved the drawing is the one those rows were written from. Reading the rows
    /// gives the labels the application shows without a second `/PageLabels` parser here.
    static func storedPageLabels(of package: ProjectPackage) async throws -> [String: [Int: String]] {
        let records = try await package.read { db in
            try PageRecord.fetchAll(db, sql: "SELECT * FROM page WHERE page_label IS NOT NULL")
        }
        var labels: [String: [Int: String]] = [:]
        for record in records {
            guard let label = record.pageLabel, !label.isEmpty else { continue }
            labels[record.documentId, default: [:]][record.pageIndex] = label
        }
        return labels
    }

    /// What `zenit verify` found (R-188).
    public struct Verification: Sendable {
        /// Whether the last session closed cleanly.
        public let closedCleanly: Bool
        /// The package checked against its own `integrity.json` (S17-07).
        public let integrity: ProjectPackage.IntegrityVerdict
        /// Schema objects no build of Zenit PDF creates, or ours altered (S17-09).
        public let schemaDeviations: [ProjectSchemaInventory.Deviation]
        /// Foreign-key violations, counted whenever the application's read-write open counts
        /// them (V-094); zero when that open would not look.
        public let foreignKeyViolations: Int

        /// Whether the application would open the project for editing without refusing it.
        ///
        /// The open path's own rules, called rather than copied (V-094): the integrity verdict's
        /// ``ProjectPackage/IntegrityVerdict/refusal(carriesCrashEvidence:)``, the foreign-key
        /// refusal, and any schema deviation. The copy this used to keep never saw the
        /// foreign-key refusal, so a package with crash evidence and violations passed `verify`
        /// with exit 0 while the application refused to open it for editing.
        public var isSound: Bool {
            integrity.refusal(carriesCrashEvidence: !closedCleanly) == nil
                && ZPDFPersistenceError.foreignKeyRefusal(violationCount: foreignKeyViolations) == nil
                && schemaDeviations.isEmpty
        }

        /// One line per problem, for the report.
        public var problems: [String] {
            var lines: [String] = []
            if integrity.error != nil { lines.append("integrity: \(integrity.outcome.rawValue): \(integrity.detail)") }
            if foreignKeyViolations > 0 { lines.append("integrity: \(foreignKeyViolations) foreign-key violation(s)") }
            for deviation in schemaDeviations {
                lines.append("schema: \(deviation.kind.rawValue) \(deviation.objectType) \(deviation.name): \(deviation.detail)")
            }
            return lines
        }
    }

    /// Checks a project the way the application's open path does, on a private copy.
    ///
    /// The old `verify` opened the copy read-only and reported only whether the last session
    /// closed cleanly — but a read-only open records the integrity verdict and the schema
    /// deviations without enforcing either, so a project edited outside Zenit PDF, or one
    /// carrying a foreign trigger, printed "integrity checked" and exited 0.
    public static func verify(_ project: URL) async throws -> Verification {
        guard project.pathExtension.lowercased() == ProjectPackageLayout.fileExtension else { throw Failure.notAProject(project.path) }
        // On a private copy: even a read-only open touches the database's index file.
        return try await withSnapshot(of: project) { copy in
            let assessment = try await ProjectPackage.assessRecovery(at: copy)
            let package = try await ProjectPackage.open(at: copy, resolving: .openReadOnly)
            let verification: Verification
            do { verification = try await Self.verification(of: package, assessment: assessment) } catch {
                try? await package.close()
                throw error
            }
            try await package.close()
            return verification
        }
    }

    /// One judgement for `verify` and for every command that reports numbers.
    static func verification(of package: ProjectPackage, assessment: RecoveryAssessment) async throws -> Verification {
        let integrity = await package.integrityVerdict
        // Counted exactly when the read-write open counts them (V-094). The read-only open this
        // reads through never does: there is no write for a violation to break there.
        let violations = integrity.needsFullCheck(carriesCrashEvidence: !assessment.isClean)
            ? try await package.database.foreignKeyViolationCount()
            : 0
        return Verification(closedCleanly: assessment.isClean,
                            integrity: integrity,
                            schemaDeviations: await package.schemaDeviations,
                            foreignKeyViolations: violations)
    }

    /// The ledger as an export projection: the whole document, flat, with the app's column set
    /// and the app's own projection options (``ExportProjectionOptions/ledgerExport``), so a
    /// `zenit export` is the application's File ▸ Export… of the same takeoff.
    ///
    /// - Parameters:
    ///   - preparedBy: the name the export is signed with. The application signs with the
    ///     person's Settings name, which this process cannot read; the default is the account's
    ///     full name, which is also the application's default.
    ///   - timestamps: the clock the report is stamped with; a test fixes it.
    public static func projection(
        _ loaded: Loaded,
        preparedBy: String = ProjectReader.machineAuthor,
        timestamps: any TimestampProviding = SystemTimestampProvider(),
        timeZone: TimeZone = .current
    ) async throws -> ExportProjection {
        let (report, _) = try await loaded.session.exportReportWithDiagnostics(
            title: ExportProjectionOptions.ledgerReportTitle(documentName: loaded.projectName), timestamps: timestamps)
        let snapshot = try await loaded.session.snapshot()
        // Values kept under an older scale are said in every format, as the application says them (K-04).
        let stale = Set(await loaded.session.staleMeasurementIDs.map(\.rawValue.uuidString))
        return try ExportProjector().project(report, options: .ledgerExport(
            documentName: loaded.projectName,
            scaleDescription: snapshot.documentScaleDescription,
            preparedBy: preparedBy,
            screenDecimalPlaces: snapshot.units.metricDecimalPlaces,
            timeZone: timeZone,
            staleScaleRowIDs: stale))
    }

    /// The account's full name, or its short name — the application's default author.
    public static var machineAuthor: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// Grand totals: one (column title, text, raw value, unit, function) per numeric column with
    /// a total, in the ledger's total rows' order (the sums, and the row counts).
    public static func totals(_ projection: ExportProjection) -> [(title: String, text: String, value: String, unit: String, function: String)] {
        var result: [(String, String, String, String, String)] = []
        for total in projection.table.grandTotals {
            for (index, column) in projection.table.columns.enumerated() where column.isNumeric && index < total.cells.count {
                guard case let .number(number) = total.cells[index] else { continue }
                result.append((column.title, number.text, number.invariantRawText, number.unitSymbol, total.function))
            }
        }
        return result
    }
}
