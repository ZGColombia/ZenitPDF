import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ZPDFUIWorkflows

/// Platform fixes, tool set half.
@Suite("Tool set platform fixes", .workflowsTierSerialised)
struct PlatformToolSetFixesTests {

    @Test("A one-tool set's confirm button reads \"Add 1 Tool\"")
    func oneToolIsSingular() {
        // Old code: String(format: "Add %d Tools", 1) → "Add 1 Tools".
        #expect(ToolSetImportReviewSheet.addToolsTitle(count: 1) == "Add 1 Tool")
        #expect(ToolSetImportReviewSheet.addToolsTitle(count: 2) == "Add 2 Tools")
        #expect(ToolSetImportReviewSheet.addToolsTitle(count: 0) == "Add 0 Tools")
    }

    @Test("The panels use the declared tool set type when the bundle exports it")
    func declaredTypeWins() throws {
        // Old code ignored the declaration and always asked for the extension's type, which is a
        // session-local `dyn.*` type whenever the running process has not seen a declaration.
        #expect(ToolSetDocument.typeIdentifier == "com.zenitgroup.zenitpdf.toolset")
        #expect(ToolSetDocument.contentType(declared: .json) == .json, "a declared type is used as is")
        let fallback = ToolSetDocument.contentType(declared: nil)
        #expect(fallback.preferredFilenameExtension == "zpdftools" || fallback == .json)
        #expect(fallback.conforms(to: .json))
    }
}
