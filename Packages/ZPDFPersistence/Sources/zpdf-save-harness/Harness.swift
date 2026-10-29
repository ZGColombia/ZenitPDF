import Darwin
import Foundation
import GRDB
import ZPDFPersistence

// A real process whose only job is to be killed halfway through a save.
//
// The durability suite launches this binary, tells it where to stop, and then inspects
// what the filesystem holds after the process is gone. Simulating the kill inside the
// test process would prove nothing: the interesting question is what survives when no
// `defer`, no `deinit` and no error path gets to run, and only an actual SIGKILL of an
// actual process answers it.
//
//   zpdf-save-harness create --package <dir> --pdf <file> [--seed <n>]
//   zpdf-save-harness save   --package <dir> [--insert <n>] [--kill-at <checkpoint>]
//
// `--kill-at` takes any `SaveCheckpoint` raw value, or `none`.

struct Arguments {
    var command: String
    var values: [String: String]

    static func parse(_ raw: [String]) -> Arguments? {
        guard raw.count >= 2 else { return nil }
        var values: [String: String] = [:]
        var index = 2
        while index + 1 < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--") else { return nil }
            values[String(key.dropFirst(2))] = raw[index + 1]
            index += 2
        }
        // A trailing flag with no value is a usage error, not a flag to drop (BH-612):
        // `--kill-at` with nothing after it used to run a full save where the test
        // expected a kill.
        guard index == raw.count else { return nil }
        return Arguments(command: raw[1], values: values)
    }

    func string(_ key: String) -> String? { values[key] }
    func integer(_ key: String, default fallback: Int) -> Int {
        values[key].flatMap(Int.init) ?? fallback
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("zpdf-save-harness: \(message)\n".utf8))
    exit(2)
}

/// Enough rows for a markup to be insertable, and enough bytes for the database copy in
/// the save pipeline to span several chunks — otherwise there is no "mid write" to stop.
func seedMarkups(
    into package: ProjectPackage,
    count: Int,
    labelPrefix: String
) async throws {
    guard count > 0 else { return }
    let blob = try GeometryBlob(
        kind: .polyline,
        points: (0..<24).map { GeometryPoint(x: Double($0) * 3.5, y: Double($0) * 1.25) }
    ).encode()
    let style = Data(repeating: 0x5A, count: 96)

    let identifiers = (0..<count).map { _ in UUID().uuidString }
    let ids = try await package.read { db -> (String, String, String)? in
        guard let documentId = try String.fetchOne(db, sql: "SELECT id FROM document LIMIT 1"),
              let projectId = try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1")
        else { return nil }
        let pageId = try String.fetchOne(db, sql: "SELECT id FROM page LIMIT 1")
        return (projectId, documentId, pageId ?? "")
    }
    guard let (_, documentId, existingPageId) = ids else { fail("package has no document row") }

    var pageId = existingPageId
    if pageId.isEmpty {
        pageId = UUID().uuidString
        let capturedPageId = pageId
        try await package.write { db in
            try PageRecord(
                id: capturedPageId, documentId: documentId, pageIndex: 0,
                mediaX: 0, mediaY: 0, mediaWidth: 1684, mediaHeight: 2384,
                cropX: 0, cropY: 0, cropWidth: 1684, cropHeight: 2384,
                rotation: 0
            ).insert(db)
        }
    }

    let timestamp = "2026-08-23T10:00:00.000Z"
    let capturedPageId = pageId
    // The whole takeoff shape of ADR-0009 rides in one transaction: a scale, the markup,
    // its measurement values and its extras, plus the takeoff_state row — so the
    // old-or-new rule is exercised over every table hydration reads, not just `markup`.
    let scaleId = UUID().uuidString
    try await package.write { db in
        let hasScale = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM scale_definition WHERE page_id = ?",
            arguments: [capturedPageId]
        ) ?? 0 > 0
        var effectiveScaleId = scaleId
        if hasScale {
            effectiveScaleId = try String.fetchOne(
                db, sql: "SELECT id FROM scale_definition WHERE page_id = ? LIMIT 1",
                arguments: [capturedPageId]
            ) ?? scaleId
        } else {
            try ScaleDefinitionRecord(
                id: scaleId, pageId: capturedPageId, name: "1:50",
                matrixA: DecimalString(text: "0.01")!, matrixB: DecimalString.zero,
                matrixC: DecimalString.zero, matrixD: DecimalString(text: "0.01")!,
                translationX: DecimalString.zero, translationY: DecimalString.zero,
                baseLengthUnit: "metre", sourceType: "calibrationTwoPoint",
                calibrationJson: nil, precisionMode: "decimalPlaces:3", version: 1,
                createdAt: timestamp, modifiedAt: timestamp
            ).insert(db)
        }
        for (offset, identifier) in identifiers.enumerated() {
            try MarkupRecord(
                id: identifier,
                documentId: documentId,
                pageId: capturedPageId,
                type: "polyline",
                subject: "\(labelPrefix) \(offset)",
                label: "\(labelPrefix)-\(offset)",
                geometryBlob: blob,
                styleBlob: style,
                scaleId: effectiveScaleId,
                scaleVersion: 1,
                createdAt: timestamp,
                modifiedAt: timestamp
            ).insert(db)
            try MeasurementValueRecord(
                markupId: identifier,
                planLengthSi: DecimalString(text: "\(offset).125")!,
                formulaVersion: 1
            ).insert(db)
            try MarkupExtraRecord(
                markupId: identifier,
                kind: "measurement",
                sortOrder: offset
            ).insert(db)
        }
        try db.execute(
            sql: "DELETE FROM takeoff_state WHERE document_id = ?", arguments: [documentId]
        )
        try TakeoffStateRecord(
            documentId: documentId, defaultScaleId: effectiveScaleId, savedAt: timestamp
        ).insert(db)
    }
}

/// SIGKILL this process: uncatchable, no unwinding, no rollback code runs.
func sigkillNow(_ label: String) -> Never {
    FileHandle.standardError.write(Data("killing at \(label)\n".utf8))
    kill(getpid(), SIGKILL)
    // SIGKILL is acted on at the next kernel transition; spin until it is.
    while true { usleep(1_000) }
}

/// Verification-owned adversarial probe (ADR-0007): inside ONE write transaction, insert a
/// markup, then append its audit entry, and SIGKILL at the named point. If the
/// same-transaction guarantee is real, a kill at `after-mutation` or `after-audit` leaves
/// NEITHER row on disk; only `none` (commit) leaves BOTH.
func runAuditCrash(package packageURL: URL, killAt: String, environment: PersistenceEnvironment) async throws {
    let package = try await ProjectPackage.open(
        at: packageURL, environment: environment, resolving: .discard
    )
    let ids = try await package.read { db -> (String, String, String)? in
        guard let projectId = try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1"),
              let documentId = try String.fetchOne(db, sql: "SELECT id FROM document LIMIT 1"),
              let pageId = try String.fetchOne(db, sql: "SELECT id FROM page LIMIT 1")
        else { return nil }
        return (projectId, documentId, pageId)
    }
    guard let (projectId, documentId, pageId) = ids else { fail("package has no project/document/page row") }

    let blob = try GeometryBlob(
        kind: .polyline,
        points: (0..<4).map { GeometryPoint(x: Double($0) * 10, y: Double($0) * 5) }
    ).encode()
    let timestamp = "2026-08-23T12:00:00.000Z"

    try await package.write { db in
        try MarkupRecord(
            id: "crash-markup",
            documentId: documentId,
            pageId: pageId,
            type: "polyline",
            subject: "audit crash probe",
            label: "crash-markup",
            geometryBlob: blob,
            styleBlob: Data(repeating: 0x5A, count: 16),
            createdAt: timestamp,
            modifiedAt: timestamp
        ).insert(db)
        if killAt == "after-mutation" { sigkillNow("after-mutation, before audit append") }
        try MeasurementAuditStore.appendAudit(
            MeasurementAuditEntry(
                id: "crash-audit",
                projectId: projectId,
                markupId: "crash-markup",
                occurredAt: timestamp,
                action: .markupCreated,
                actor: "harness",
                afterValues: ["length": "12.50"]
            ),
            in: db
        )
        if killAt == "after-audit" { sigkillNow("after audit append, before commit") }
    }
    try await package.close()
    print("committed both")
}

func makeHooks(killAt: SaveCheckpoint?) -> SaveHooks {
    guard let killAt else { return .none }
    return SaveHooks { checkpoint in
        guard checkpoint == killAt else { return }
        FileHandle.standardError.write(Data("killing at \(checkpoint.rawValue)\n".utf8))
        // Uncatchable, unhandled, no unwinding: exactly the failure the user's power
        // strip produces.
        kill(getpid(), SIGKILL)
        // `kill` returns before the signal is acted on: SIGKILL is processed at the next
        // transition through the kernel, so the instruction after this one can still
        // run. Spin on a syscall until the kernel gets round to us.
        while true { usleep(1_000) }
    }
}

@main
enum Harness {
    static func main() async {
        guard let arguments = Arguments.parse(CommandLine.arguments) else {
            fail("usage: zpdf-save-harness <create|save> --package <dir> [...]")
        }
        guard let packagePath = arguments.string("package") else { fail("--package is required") }
        let packageURL = URL(fileURLWithPath: packagePath)
        let environment = PersistenceEnvironment(appVersion: "1.0.0-harness")

        do {
            switch arguments.command {
            case "create":
                guard let pdfPath = arguments.string("pdf") else { fail("--pdf is required") }
                let package = try await ProjectPackage.create(
                    at: packageURL,
                    displayName: arguments.string("name") ?? "Harness",
                    originalPDF: URL(fileURLWithPath: pdfPath),
                    pageCount: 1,
                    environment: environment
                )
                try await seedMarkups(
                    into: package,
                    count: arguments.integer("seed", default: 0),
                    labelPrefix: "seed"
                )
                let receipt = try await package.save()
                try await package.close()
                print("created generation \(receipt.integrity.generation)")

            case "save":
                let killAt = arguments.string("kill-at").flatMap { raw -> SaveCheckpoint? in
                    raw == "none" ? nil : SaveCheckpoint(rawValue: raw)
                }
                if let raw = arguments.string("kill-at"), raw != "none", killAt == nil {
                    fail("unknown checkpoint \(raw)")
                }
                let package = try await ProjectPackage.open(
                    at: packageURL, environment: environment, resolving: .discard
                )
                try await seedMarkups(
                    into: package,
                    count: arguments.integer("insert", default: 0),
                    labelPrefix: "added"
                )
                let receipt = try await package.save(hooks: makeHooks(killAt: killAt))
                try await package.close()
                print("saved generation \(receipt.integrity.generation)")

            case "audit-crash":
                let killAt = arguments.string("kill") ?? "none"
                guard ["after-mutation", "after-audit", "none"].contains(killAt) else {
                    fail("unknown kill point \(killAt)")
                }
                try await runAuditCrash(package: packageURL, killAt: killAt, environment: environment)

            default:
                fail("unknown command \(arguments.command)")
            }
        } catch {
            fail("\(error)")
        }
        exit(0)
    }
}
