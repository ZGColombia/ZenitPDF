import Foundation

/// The one named colour palette every UI package offers (IM-208).
///
/// Cyan, blue, green, amber and coral over the Graphite Workshop dark tokens, each with a
/// localised name so VoiceOver and menus never describe a colour by its hex value. The Tool
/// Library's `ZenitMarkupPalette` (zones, revision overlays) and the Scale Regions'
/// `ZenitRegionPalette` are typealiases of this type: the list used to be written out three
/// times, so a token change reached one colour picker and not the others (W-075).
public enum ZenitNamedPalette {

    /// One named colour.
    public struct Entry: Identifiable, Hashable, Sendable {
        /// Stable identity, never localised.
        public let id: String
        /// The spoken name.
        public let name: String
        /// The colour itself.
        public let color: ColorRGBA

        public init(id: String, name: String, color: ColorRGBA) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    /// The palette, in display order.
    public static let entries: [Entry] = [
        Entry(id: "cyan", name: NSLocalizedString("Cyan", comment: "Markup colour name"), color: ColorRGBA.Zenit.Dark.cyan),
        Entry(id: "blue", name: NSLocalizedString("Blue", comment: "Markup colour name"), color: ColorRGBA.Zenit.Dark.blue),
        Entry(id: "green", name: NSLocalizedString("Green", comment: "Markup colour name"), color: ColorRGBA.Zenit.Dark.green),
        Entry(id: "amber", name: NSLocalizedString("Amber", comment: "Markup colour name"), color: ColorRGBA.Zenit.Dark.warning),
        Entry(id: "coral", name: NSLocalizedString("Coral", comment: "Markup colour name"), color: ColorRGBA.Zenit.Dark.danger)
    ]

    /// The colour for an identifier, or the first entry when the identifier is unknown.
    public static func color(for id: String) -> ColorRGBA {
        entries.first { $0.id == id }?.color ?? entries[0].color
    }

    /// The entry for an identifier, or the first entry when the identifier is unknown.
    public static func entry(for id: String) -> Entry {
        entries.first { $0.id == id } ?? entries[0]
    }

    /// The spoken name of the palette colour nearest to `color`.
    ///
    /// A picker only ever stores palette colours, so this is normally an exact match; nearest
    /// keeps a colour from an older file nameable rather than falling back to a hex code.
    public static func name(for color: ColorRGBA) -> String {
        func distance(_ entry: Entry) -> Double {
            let dr = entry.color.red - color.red
            let dg = entry.color.green - color.green
            let db = entry.color.blue - color.blue
            return dr * dr + dg * dg + db * db
        }
        return entries.min { distance($0) < distance($1) }?.name ?? entries[0].name
    }
}
