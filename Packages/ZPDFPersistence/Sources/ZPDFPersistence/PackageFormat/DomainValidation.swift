import Foundation
import GRDB

/// The first stage of the save pipeline: refuse to write a project that is already wrong.
///
/// Foreign keys catch dangling references. These are the invariants SQLite cannot state
/// — a page rotated 47 degrees, a markup that claims a scale but not which generation
/// of it, a document whose file lives outside the package. Every check is one aggregate
/// query, so validating a 100 000-markup project is a handful of index scans rather
/// than a row loop; nothing here materialises the table.
public enum DomainValidation {

    /// Runs every check and returns what it found. An empty array means the save may
    /// proceed.
    ///
    /// - Parameter checkForeignKeys: whether to run `PRAGMA foreign_key_check`, which
    ///   walks every child table including `ocr_token`. `foreign_keys` is on for every
    ///   connection this package opens, so a write of ours cannot leave a violation; one
    ///   can only arrive from outside, and the open path runs the check for exactly the
    ///   packages that could carry one — crash evidence or a failed verification. The
    ///   save pipeline passes `false` (IM-194); every other caller keeps the default.
    public static func validate(_ db: Database, checkForeignKeys: Bool = true) throws -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // Exactly one project row: the file is a project, singular.
        let projectCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") ?? 0
        if projectCount != 1 {
            issues.append(ValidationIssue(
                subject: "project",
                code: "project-row-count",
                detail: "expected exactly one project row, found \(projectCount)"
            ))
        }

        let schemaVersions = try Int.fetchAll(db, sql: "SELECT schema_version FROM project")
        for version in schemaVersions where version != ProjectSchema.currentVersion {
            issues.append(ValidationIssue(
                subject: "project",
                code: "schema-version-mismatch",
                detail: "project.schema_version is \(version), this build writes \(ProjectSchema.currentVersion)"
            ))
        }

        // Documents live inside the package, under documents/. A relative_path that
        // escapes the package would make the project unopenable on another machine.
        // `GLOB` and `instr`, not `LIKE` (BH-597): SQLite's `LIKE` is case-insensitive
        // for ASCII, so 'Documents/plan.pdf' used to pass as living inside `documents/`
        // and then failed to resolve on a case-sensitive volume — the exact project this
        // check exists to refuse.
        let escapingDocuments = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM document
            WHERE relative_path NOT GLOB 'documents/*'
               OR instr(relative_path, '..') > 0
            """) ?? 0
        if escapingDocuments > 0 {
            issues.append(ValidationIssue(
                subject: "document",
                code: "relative-path-outside-package",
                detail: "\(escapingDocuments) document row(s) point outside documents/"
            ))
        }

        // `NOT GLOB '[0-9a-f]*'` constrained only the FIRST character: "a" followed by 63 bytes
        // of junk passed as a SHA-256 (CR-87). `GLOB '*[^0-9a-f]*'` is true when the string
        // contains any character outside lowercase hex, constraining the whole string.
        let badHashes = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM document
            WHERE length(sha256) <> 64 OR sha256 GLOB '*[^0-9a-f]*'
            """) ?? 0
        if badHashes > 0 {
            issues.append(ValidationIssue(
                subject: "document",
                code: "malformed-sha256",
                detail: "\(badHashes) document row(s) do not carry a lowercase hex SHA-256"
            ))
        }

        // Page geometry.
        let badRotation = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM page WHERE rotation NOT IN (0, 90, 180, 270)
            """) ?? 0
        if badRotation > 0 {
            issues.append(ValidationIssue(
                subject: "page",
                code: "rotation-not-quarter-turn",
                detail: "\(badRotation) page(s) have a rotation that is not 0, 90, 180 or 270"
            ))
        }

        let badBoxes = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM page
            WHERE media_width <= 0 OR media_height <= 0
               OR crop_width <= 0 OR crop_height <= 0
            """) ?? 0
        if badBoxes > 0 {
            issues.append(ValidationIssue(
                subject: "page",
                code: "non-positive-page-box",
                detail: "\(badBoxes) page(s) have a media or crop box with a non-positive extent"
            ))
        }

        // A markup measured against a scale must say which generation of it, or a later
        // scale edit cannot tell stale rows from fresh ones.
        let scaleWithoutVersion = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM markup WHERE scale_id IS NOT NULL AND scale_version IS NULL
            """) ?? 0
        if scaleWithoutVersion > 0 {
            issues.append(ValidationIssue(
                subject: "markup",
                code: "scale-version-missing",
                detail: "\(scaleWithoutVersion) markup(s) reference a scale without recording its version"
            ))
        }

        let badTimestamps = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM markup
            WHERE length(created_at) <> 24 OR length(modified_at) <> 24
            """) ?? 0
        if badTimestamps > 0 {
            issues.append(ValidationIssue(
                subject: "markup",
                code: "malformed-timestamp",
                detail: "\(badTimestamps) markup(s) do not carry an ISO-8601 millisecond timestamp"
            ))
        }

        // Decimal columns hold decimal strings. This is a cheap shape check, not a
        // parse: the strict parse happens in DecimalString at read time.
        let decimalColumns = [
            "count_value", "plan_length_si", "true_length_si", "perimeter_si",
            "plan_area_si", "true_area_si", "wall_area_si", "volume_si",
            "rise_si", "run_si", "slope_ratio", "slope_percent",
            "slope_angle_radians", "depth_si", "height_si", "radius_si", "diameter_si"
        ]
        // As with the SHA-256 check, `NOT GLOB '[-+.0-9]*'` tested only the first character, so
        // "1; DROP" passed the shape check (CR-87). `= '' OR GLOB '*[^-+.0-9eE]*'` flags an empty
        // value or one containing any character a decimal string may not (digits, sign, dot and
        // an exponent marker are the whole vocabulary; the strict parse stays in DecimalString).
        let predicate = decimalColumns
            .map { "(\($0) IS NOT NULL AND (\($0) = '' OR \($0) GLOB '*[^-+.0-9eE]*'))" }
            .joined(separator: " OR ")
        let badDecimals = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM measurement_value WHERE \(predicate)"
        ) ?? 0
        if badDecimals > 0 {
            issues.append(ValidationIssue(
                subject: "measurement_value",
                code: "non-decimal-text",
                detail: "\(badDecimals) measurement row(s) hold text that is not a decimal"
            ))
        }

        // A column definition (v11) is JSON the application wrote, a few hundred bytes. One
        // that is not JSON, or is far larger than any definition, did not come from us.
        if try db.columns(in: "custom_column").contains(where: { $0.name == "definition_json" }) {
            let badDefinitions = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM custom_column
                WHERE definition_json IS NOT NULL
                  AND (length(definition_json) > \(CustomColumnStore.maximumDefinitionByteCount)
                       OR NOT json_valid(definition_json))
                """) ?? 0
            if badDefinitions > 0 {
                issues.append(ValidationIssue(
                    subject: "custom_column",
                    code: "malformed-column-definition",
                    detail: "\(badDefinitions) custom column(s) carry a definition that is not a JSON column definition"
                ))
            }
        }

        // Belt and braces over the foreign keys that are already enforced: a project
        // that was edited by another tool, or restored from a partial copy, can have
        // violations that only surface here.
        if checkForeignKeys {
            let violations = try foreignKeyViolationCount(db)
            if violations > 0 {
                issues.append(ValidationIssue(
                    subject: "database",
                    code: "foreign-key-violation",
                    detail: "\(violations) foreign-key violation(s)"
                ))
            }
        }

        return issues
    }

    /// `PRAGMA foreign_key_check`, as a count. The open path runs it on its own for a
    /// package carrying crash evidence or a failed verification (IM-194).
    public static func foreignKeyViolationCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? 0
    }
}
