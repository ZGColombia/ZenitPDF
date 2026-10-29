import Foundation
import ZPDFUIPresentation

/// Suggestions from context (NL-AUTO-21): the drawing layer a measurement was traced on names
/// what it probably is. A traced area whose walls sit on `A-FLOR-FINISH` probably wants the
/// "Floor finish" tool's subject; one on a layer named like a Project Zone ("LEVEL 2") probably
/// belongs to that zone. Deterministic token matching, no model: a suggestion is offered in the
/// warning tray and **never applied** by itself.
public enum LayerContextSuggester {

    /// What the layer suggests. Either part may be absent.
    public struct Suggestion: Sendable, Equatable {
        public var subject: String?
        /// The preset whose words matched, for the offer's wording.
        public var presetName: String?
        public var zoneID: UUID?
        public var zoneName: String?
        public var isEmpty: Bool { subject == nil && zoneID == nil }
    }

    /// The words of a layer, preset or zone name: split on anything that is not a letter or a
    /// digit, lower-cased; a single letter (a discipline prefix such as `A-`) is dropped, a
    /// number is kept whatever its length — "Level 2" is not "Level 3".
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
    }

    /// Whether two words name the same thing: equal, or one is the other's start of at least
    /// four letters — `flor` and `floor` do not, `floo` and `floor` do; CAD layer names are
    /// abbreviations, so an abbreviation of four or more letters counts.
    static func match(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short)
    }

    /// How many of `candidate`'s words the layer's words match.
    static func score(layer: [String], candidate: [String]) -> Int {
        candidate.filter { word in layer.contains { match($0, word) } }.count
    }

    /// The suggestion for a measurement traced on `layerName`, given the presets and zones the
    /// project has. A preset needs at least one matching word (one-letter words, such as a
    /// discipline prefix `A-`, never count) and a zone needs all of its words; the best score
    /// wins, ties go to the first in library order.
    public static func suggest(layerName: String, presets: [ToolPresetSummary], zones: [ProjectZoneSummary], currentSubject: String) -> Suggestion {
        let layer = words(layerName)
        var suggestion = Suggestion()
        guard !layer.isEmpty else { return suggestion }
        var bestPreset: (score: Int, preset: ToolPresetSummary)?
        for preset in presets where preset.markupKind == .measurement {
            let candidate = Set(words(preset.name) + words(preset.defaultSubject)).sorted()
            let value = score(layer: layer, candidate: candidate)
            if value > 0, value > (bestPreset?.score ?? 0) { bestPreset = (value, preset) }
        }
        if let preset = bestPreset?.preset {
            let subject = preset.defaultSubject.isEmpty ? preset.name : preset.defaultSubject
            if subject.caseInsensitiveCompare(currentSubject) != .orderedSame {
                suggestion.subject = subject
                suggestion.presetName = preset.name
            }
        }
        var bestZone: (score: Int, zone: ProjectZoneSummary)?
        for zone in zones {
            let value = score(layer: layer, candidate: words(zone.name))
            // A zone must match all its words: "Level 2" wants both "level" and "2".
            let needed = words(zone.name).count
            if value > 0, value == needed, value > (bestZone?.score ?? 0) { bestZone = (value, zone) }
        }
        if let zone = bestZone?.zone {
            suggestion.zoneID = zone.id
            suggestion.zoneName = zone.name
        }
        return suggestion
    }
}
