import AppKit
@testable import ZenitPDFAppKit

@MainActor
enum CanvasPillTestSupport {
    static let pillTextAttributes: [NSAttributedString.Key: Any] = [
        .font: CanvasMarkupStyle.pillFont,
        .foregroundColor: CanvasMarkupStyle.pillTextColor(.light)
    ]
}
