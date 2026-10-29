import Foundation
import ZPDFUIPresentation

/// Starter job templates that ship with the app (NL-PLAT-22): Zenit's own presets for common
/// trades, offered beside the person's own templates in Tools ▸ Job Templates ▸ Apply. Like every
/// job template they carry presets, subjects and units — and structurally never a scale
/// (`JobTemplate` has no key for one), so a starter can never pretend to know a drawing's scale.
///
/// Stable ids (a fixed namespace per template and preset) so applying a starter twice updates the
/// same presets instead of piling up copies.
public enum StarterJobTemplates {

    public static var all: [JobTemplate] { [flooring, painting, groundwork, electrical] }

    static func id(_ name: String) -> UUID {
        // Deterministic: the name's bytes folded into a v4-shaped UUID. Not a hash of anything a
        // person typed; only these literals reach it.
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Array("zenit.starter.\(name)".utf8).enumerated() { bytes[index % 16] = bytes[index % 16] &* 31 &+ byte }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func preset(_ key: String, _ name: String, _ category: String, _ kind: MeasurementKind, _ color: ColorRGBA,
                       subject: String, defaults: ToolPresetMeasurementDefaults = .none, markup: ZPDFUIPresentation.MarkupKind = .measurement) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id(key), name: name, category: category, panel: .myTools, markupKind: markup, measurementKind: kind,
            colorRGBA: color, defaultSubject: subject, measurementDefaults: defaults,
            provenance: ToolPresetProvenance(origin: .createdHere), sortIndex: 0
        )
    }

    static func metres(_ value: Decimal) -> ZPDFUIPresentation.DecimalQuantity { ZPDFUIPresentation.DecimalQuantity(value: value, dimension: .length) }

    static let blue = ColorRGBA(red: 0.13, green: 0.40, blue: 0.80)
    static let green = ColorRGBA(red: 0.16, green: 0.60, blue: 0.30)
    static let orange = ColorRGBA(red: 0.90, green: 0.50, blue: 0.10)
    static let red = ColorRGBA(red: 0.80, green: 0.15, blue: 0.20)
    static let purple = ColorRGBA(red: 0.50, green: 0.25, blue: 0.70)

    static func name(_ english: String, _ comment: String) -> String { NSLocalizedString(english, comment: comment) }

    public static var flooring: JobTemplate {
        let category = name("Flooring", "Starter template category and name")
        return JobTemplate(
            id: id("flooring"),
            name: name("Starter: Flooring", "Starter job template name"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            presets: [
                preset("flooring.area", name("Floor finish", "Starter preset"), category, .area, blue, subject: name("Floor finish", "Starter preset")),
                preset("flooring.skirting", name("Skirting", "Starter preset"), category, .polylength, green, subject: name("Skirting", "Starter preset")),
                preset("flooring.threshold", name("Threshold", "Starter preset"), category, .count, orange, subject: name("Threshold", "Starter preset")),
            ],
            subjects: [JobTemplateSubject(name: name("Floor finish", "Starter preset"), colorRGBA: blue)]
        )
    }

    public static var painting: JobTemplate {
        let category = name("Painting", "Starter template category and name")
        var walls = ToolPresetMeasurementDefaults.none
        walls.wallHeight = metres(Decimal(string: "2.5")!)
        return JobTemplate(
            id: id("painting"),
            name: name("Starter: Painting", "Starter job template name"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            presets: [
                preset("painting.walls", name("Walls, 2.5 m", "Starter preset"), category, .wallArea, purple,
                       subject: name("Wall paint", "Starter preset"), defaults: walls),
                preset("painting.ceiling", name("Ceiling", "Starter preset"), category, .area, blue, subject: name("Ceiling paint", "Starter preset")),
            ]
        )
    }

    public static var groundwork: JobTemplate {
        let category = name("Groundwork", "Starter template category and name")
        var excavation = ToolPresetMeasurementDefaults.none
        excavation.depth = metres(Decimal(string: "0.3")!)
        return JobTemplate(
            id: id("groundwork"),
            name: name("Starter: Groundwork", "Starter job template name"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            presets: [
                preset("groundwork.excavation", name("Excavation, 300 mm", "Starter preset"), category, .volume, orange,
                       subject: name("Excavation", "Starter preset"), defaults: excavation),
                preset("groundwork.trench", name("Trench", "Starter preset"), category, .polylength, red, subject: name("Trench", "Starter preset")),
                preset("groundwork.paving", name("Paving", "Starter preset"), category, .area, green, subject: name("Paving", "Starter preset")),
            ]
        )
    }

    public static var electrical: JobTemplate {
        let category = name("Electrical", "Starter template category and name")
        return JobTemplate(
            id: id("electrical"),
            name: name("Starter: Electrical counts", "Starter job template name"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            presets: [
                preset("electrical.socket", name("Socket outlet", "Starter preset"), category, .count, red, subject: name("Socket outlet", "Starter preset")),
                preset("electrical.switch", name("Switch", "Starter preset"), category, .count, blue, subject: name("Switch", "Starter preset")),
                preset("electrical.light", name("Light fitting", "Starter preset"), category, .count, orange, subject: name("Light fitting", "Starter preset")),
                preset("electrical.cable", name("Cable run", "Starter preset"), category, .polylength, purple, subject: name("Cable run", "Starter preset")),
            ]
        )
    }
}
