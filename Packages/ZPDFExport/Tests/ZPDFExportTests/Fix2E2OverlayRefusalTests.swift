import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// Bug hunt 2: a `.zpdfoverlay` that is corrupted is refused with a sentence naming
/// the overlay format — never imported with a field quietly dropped.
@Suite(.sharedHeap)
struct Fix2E2OverlayRefusalTests {

    /// The golden overlay, re-serialised after `edit` has changed its JSON tree.
    static func overlay(editing edit: (inout [String: Any]) -> Void) throws -> Data {
        let data = try MeasurementOverlayTests.overlayData()
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Changes the first measurement that carries geometry.
    static func editFirstGeometry(
        _ root: inout [String: Any],
        _ change: (inout [String: Any]) -> Void
    ) {
        guard var measurements = root["measurements"] as? [[String: Any]] else { return }
        for index in measurements.indices {
            guard var geometry = measurements[index]["geometry"] as? [String: Any] else { continue }
            change(&geometry)
            measurements[index]["geometry"] = geometry
            break
        }
        root["measurements"] = measurements
    }

    static func editFirstCountPoint(_ root: inout [String: Any], key: String, value: Any) {
        editFirstGeometry(&root) { geometry in
            guard var points = geometry["countPoints"] as? [[String: Any]], !points.isEmpty else {
                return
            }
            points[0][key] = value
            geometry["countPoints"] = points
        }
    }

    static func overlayRefusal(_ data: Data) -> String? {
        do {
            _ = try ZenitOverlayImporter().document(from: data)
        } catch let ExportError.malformedOverlay(detail) {
            return detail
        } catch {
            return "other: \(error)"
        }
        return nil
    }

    // MARK: - BH-524

    @Test("BH-524: a wrong-typed sequenceNumber, groupID or symbolID is refused, not dropped")
    func wrongTypedCountFieldsAreRefused() throws {
        // Old: `"sequenceNumber": "7"` decoded as nil and `"groupID": 12` as no group, so the
        // count point lost its numbering and membership while the import reported success.
        // (A non-integral number such as 7.5 is already refused by the shared JSON reader.)
        let cases: [(String, Any)] = [
            ("sequenceNumber", "7"),
            ("sequenceNumber", ["7"]),
            ("groupID", 12),
            ("symbolID", true)
        ]
        for (key, value) in cases {
            let data = try Self.overlay { Self.editFirstCountPoint(&$0, key: key, value: value) }
            let detail = Self.overlayRefusal(data)
            #expect(detail?.contains(key) == true, "\(key) = \(value): \(detail ?? "imported")")
        }
        // `null` is still "none", which is what the writer emits.
        let unnumbered = try Self.overlay {
            Self.editFirstCountPoint(&$0, key: "sequenceNumber", value: NSNull())
        }
        let document = try ZenitOverlayImporter().document(from: unnumbered)
        let point = try #require(document.measurements.compactMap(\.geometry).first?.countPoints.first)
        #expect(point.sequenceNumber == nil)
        #expect(point.groupID != nil)
    }

    // MARK: - BH-525

    @Test("BH-525: a truncated or oversized overlay is reported as a .zpdfoverlay problem")
    func overlayErrorsNameTheOverlayFormat() throws {
        // Old: malformedInterchange / interchangeTooLarge — "the .zpdfjson document is ...".
        let data = try MeasurementOverlayTests.overlayData()
        let truncated = data.prefix(data.count / 2)
        do {
            _ = try ZenitOverlayImporter().document(from: Data(truncated))
            Issue.record("a truncated overlay was imported")
        } catch let error as ExportError {
            guard case .malformedOverlay = error else {
                Issue.record("expected malformedOverlay, got \(error)")
                return
            }
            #expect(error.description.contains(".zpdfoverlay"))
            #expect(!error.description.contains(".zpdfjson"))
        }

        let oversized = Data(count: ZenitOverlayDocument.maximumByteCount + 1)
        do {
            _ = try ZenitOverlayImporter().document(from: oversized)
            Issue.record("an oversized overlay was read")
        } catch let error as ExportError {
            #expect(error.description.contains(".zpdfoverlay"), "\(error)")
            #expect(!error.description.contains(".zpdfjson"))
        }
    }

    // MARK: - BH-526

    @Test("BH-526: geometry that is a string or an array is refused, not imported as 'no geometry'")
    func nonObjectGeometryIsRefused() throws {
        // Old: `if let encoded = value["geometry"], case .object = encoded` sent both to
        // `geometry = nil`, and the row imported with its drawing silently gone.
        for replacement in ["M 0 0 L 10 10", [1, 2, 3]] as [Any] {
            let data = try Self.overlay { root in
                guard var measurements = root["measurements"] as? [[String: Any]],
                      !measurements.isEmpty else { return }
                measurements[0]["geometry"] = replacement
                root["measurements"] = measurements
            }
            let detail = Self.overlayRefusal(data)
            #expect(detail?.contains("geometry") == true, "\(replacement): \(detail ?? "imported")")
        }
        // Absent and null are both "no geometry".
        let withNull = try Self.overlay { root in
            guard var measurements = root["measurements"] as? [[String: Any]] else { return }
            for index in measurements.indices { measurements[index]["geometry"] = NSNull() }
            root["measurements"] = measurements
        }
        let document = try ZenitOverlayImporter().document(from: withNull)
        #expect(document.measurements.allSatisfy { $0.geometry == nil })
    }
}
