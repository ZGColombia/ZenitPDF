import ZPDFExport
import ZenitPDFAppKit

/// A destination that keeps what it was handed. Used by the app-tier tests, which must be able
/// to compare the bytes of three exports without any of them reaching the machine's clipboard.
final class RecordingSnippetPasteboard: SnippetPasteboardWriting {
    private(set) var payloads: [SnippetPasteboardPayload] = []

    init() {}

    func write(_ payload: SnippetPasteboardPayload) {
        payloads.append(payload)
    }
}
