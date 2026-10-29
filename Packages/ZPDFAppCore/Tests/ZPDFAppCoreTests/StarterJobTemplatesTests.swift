import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFUIPresentation

/// NL-PLAT-22: the shipped starter templates are real templates, stable, and carry no scale.
@Suite("Starter job templates — NL-PLAT-22")
struct StarterJobTemplatesTests {

    @Test("Four starters, each with presets, stable ids, and a file round trip that carries no scale")
    func startersAreSound() throws {
        let all = StarterJobTemplates.all
        #expect(all.count == 4)
        #expect(all.allSatisfy { !$0.presets.isEmpty && $0.name.hasPrefix("Starter: ") })
        #expect(Set(all.map(\.id)).count == 4)
        #expect(StarterJobTemplates.all.map(\.id) == all.map(\.id), "ids are stable across calls")
        let presetIDs = all.flatMap(\.presets).map(\.id)
        #expect(Set(presetIDs).count == presetIDs.count)
        // The painting walls carry their height, the groundwork excavation its depth: 2.5 m and 0.3 m.
        #expect(StarterJobTemplates.painting.presets.first?.measurementDefaults.wallHeight?.value == Decimal(string: "2.5"))
        #expect(StarterJobTemplates.groundwork.presets.first?.measurementDefaults.depth?.value == Decimal(string: "0.3"))
        for template in all {
            let data = try JobTemplateFile.export(template)
            let text = String(decoding: data, as: UTF8.self).lowercased()
            #expect(!text.contains("\"scale\""), "\(template.name) must never carry a scale")
            #expect(try JobTemplateFile.read(data).presets.count == template.presets.count)
        }
    }
}
