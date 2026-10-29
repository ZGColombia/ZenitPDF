import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import ZPDFUIPresentation

/// What travels on the pasteboard when a tool preset is dragged onto the canvas.
///
/// Only the identity and a human-readable name travel. The receiving canvas looks the preset up
/// in the library it already trusts, so a drag can never smuggle a tool definition in.
public struct ToolPresetDragPayload: Codable, Hashable, Sendable, Transferable {

    /// Identity of the preset in the Tool Library.
    public var presetID: UUID
    /// The preset's name, so a drop target can describe the drag before resolving it.
    public var name: String

    /// Creates a drag payload.
    public init(presetID: UUID, name: String) {
        self.presetID = presetID
        self.name = name
    }

    /// Creates a drag payload for a preset.
    public init(preset: ToolPresetSummary) {
        self.init(presetID: preset.id, name: preset.name)
    }

    /// JSON on the pasteboard. No custom system type is registered, so the package works in any
    /// host without an `Info.plist` declaration.
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
