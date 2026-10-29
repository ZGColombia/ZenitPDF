import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A `.zpdftools` file for the save panel.
///
/// Reading goes through ``ToolSetImportValidator`` rather than this type: a document read here
/// would be trusted by construction, and a tool set is never trusted by construction.
public struct ToolSetFileDocument: FileDocument, Sendable {

    /// The types the save panel offers.
    public static var readableContentTypes: [UTType] { [ToolSetDocument.contentType] }

    /// The set being written.
    public var document: ToolSetDocument

    /// Creates a file document around a tool set.
    public init(document: ToolSetDocument) {
        self.document = document
    }

    /// Reads a file the system handed us. The contents are re-checked by the validator before
    /// anything reaches the Tool Library.
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.document = try decoder.decode(ToolSetDocument.self, from: data)
    }

    /// Writes the set as pretty-printed JSON.
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try document.jsonData())
    }
}
