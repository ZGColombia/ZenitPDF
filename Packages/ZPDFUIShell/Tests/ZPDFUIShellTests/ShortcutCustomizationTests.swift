import Foundation
import Testing
@testable import ZPDFUIShell

/// NL-UX-11, customisable shortcuts. Acceptance: Settings lists the command table;
/// a rebinding reuses the table's conflict audit and refuses a clash naming the other command;
/// the menu bar is rebuilt and the shortcut reference follows (app tier).
@MainActor
@Suite("Customisable shortcuts", .shellTierSerialised)
struct ShortcutCustomizationTests {

    /// An existing scratch prefix, so this suite adds no preference file.
    private static let prefix = "zenit.test.ledgerpane"

    @Test("A free chord is accepted, stored, and in force in the effective table")
    func rebindToFreeChord() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: Self.prefix)
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let store = ZPDFShortcutOverrideStore(defaults: defaults)
        let model = ShortcutSettingsModel(store: store)
        var applied: [ZPDFCommandTable] = []
        model.onApply = { applied.append($0) }

        #expect(model.assign(.character("j", [.command, .option]), to: .toggleCoverageMap))
        #expect(model.effectiveTable.command(.toggleCoverageMap)?.binding?.displayString == "⌥⌘J")
        #expect(applied.count == 1)
        // Stored, and read back by a fresh store.
        #expect(ZPDFShortcutOverrideStore(defaults: defaults).overrides.override(for: .toggleCoverageMap) != nil)
        // The whole table still passes its own audits.
        let table = model.effectiveTable
        #expect(table.conflicts().isEmpty)
        #expect(table.undeclaredShadows().isEmpty)
        #expect(table.systemShortcutTakeovers().isEmpty)
    }

    @Test("A clash is refused, naming the other command, and changes nothing")
    func clashIsRefused() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: Self.prefix)
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let model = ShortcutSettingsModel(store: ZPDFShortcutOverrideStore(defaults: defaults))
        let saveTitle = try #require(ZPDFCommandTable.standard.command(.save)?.title)

        #expect(!model.assign(.character("s", [.command]), to: .toggleCoverageMap))
        #expect(model.refusal?.contains(saveTitle) == true, "\(model.refusal ?? "nil")")
        #expect(model.overrides.isEmpty)
    }

    @Test("System chords, digits and ⌘-less non-canvas shortcuts are refused; canvas letters are not")
    func ruleRefusals() {
        let table = ZPDFCommandTable.standard
        #expect(table.validate(.character("q", [.command]), for: .toggleCoverageMap) == .reservedBySystem)
        #expect(table.validate(.character("3", []), for: .measureLength) == .reservedForToolSlots)
        #expect(table.validate(.character("j", []), for: .toggleCoverageMap) == .needsCommandKey)
        // Area is a canvas tool: a single free letter is fine for it.
        #expect(table.validate(.character("g", []), for: .measureArea) == nil)
        // Application chords outside the table are respected too.
        #expect(table.validate(.character("p", [.command, .shift]), for: .toggleCoverageMap,
                               reservedChords: [ZPDFKeyBinding.character("p", [.command, .shift]).chord: "Command Palette…"])
                == .takenBy(commandTitle: "Command Palette…"))
    }

    @Test("A recorded chord lands on the command being recorded; Default and Restore All undo it")
    func recordAndRestore() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: Self.prefix)
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let model = ShortcutSettingsModel(store: ZPDFShortcutOverrideStore(defaults: defaults))
        model.beginRecording(.fitPage)
        let chord = try #require(ShortcutRecorderInput.binding(characters: "9", command: true, shift: false, option: true, control: false))
        #expect(model.record(chord))
        #expect(model.recording == nil)
        #expect(model.effectiveTable.command(.fitPage)?.binding?.displayString == "⌥⌘9")
        #expect(model.rows.first { $0.id == .fitPage }?.isCustomised == true)

        #expect(model.restore(.fitPage))
        #expect(model.effectiveTable.command(.fitPage)?.binding == ZPDFCommandTable.standard.command(.fitPage)?.binding)

        model.clear(.fitPage)
        #expect(model.effectiveTable.command(.fitPage)?.binding == nil)
        model.restoreAll()
        #expect(model.overrides.isEmpty)
        #expect(ZPDFShortcutOverrideStore(defaults: defaults).overrides.isEmpty)
    }

    @Test("Setting a command back to its standard chord drops the override")
    func standardChordDropsOverride() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: Self.prefix)
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let model = ShortcutSettingsModel(store: ZPDFShortcutOverrideStore(defaults: defaults))
        #expect(model.assign(.character("j", [.command, .option]), to: .fitWidth))
        let standard = try #require(ZPDFCommandTable.standard.command(.fitWidth)?.binding)
        #expect(model.assign(standard, to: .fitWidth))
        #expect(model.overrides.isEmpty)
    }

    @Test("Overrides round-trip through JSON, including an explicit removal")
    func overridesCodable() throws {
        var overrides = ZPDFShortcutOverrides()
        overrides.bindings[ZPDFCommandID.fitPage.rawValue] = .some(nil)
        overrides.bindings[ZPDFCommandID.zoomIn.rawValue] = .some(.character("=", [.command, .option]))
        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(ZPDFShortcutOverrides.self, from: data)
        #expect(decoded == overrides)
        let table = ZPDFCommandTable.standard.applying(decoded)
        #expect(table.command(.fitPage)?.binding == nil)
        #expect(table.command(.zoomIn)?.binding?.displayString == "⌥⌘=")
    }
}
