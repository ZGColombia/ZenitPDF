import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// One of the drawing's own links, in page space (NL-DOCS-09). Issued sets link detail bubbles
/// and sheet references to their sheets; the canvas is Zenit's own renderer, so without this a
/// click on such a link did nothing.
public struct DrawingLink: Sendable, Hashable {

    /// Where a link goes. Described, never executed: a script or a launch is shown to the person
    /// and not run; a web address is opened only after they say so.
    public enum Target: Sendable, Hashable {
        case page(Int)
        /// A sheet of the project by identity — a hyperlink markup's page target (ADR-0029). A
        /// PDF index names a page only within its own drawing, so a markup that names a page
        /// by identity is followed by identity (r2-layers follow-up, 2026-09-26).
        case sheet(UUID)
        case namedDestination(String)
        case uri(String)
        case script
        case launch
        case unsupported
    }

    public let bounds: CGRect
    public let target: Target
    /// Where a sheet link lands on its page, each axis `nil` when the link leaves it to the
    /// reader (NL-DOCS-09, BH-586 semantics).
    public var left: Double?
    public var top: Double?

    public init(bounds: CGRect, target: Target, left: Double? = nil, top: Double? = nil) {
        self.bounds = bounds
        self.target = target
        self.left = left
        self.top = top
    }

    /// A link annotation as a link; `nil` for any other annotation, or a link with no action.
    init?(annotation: NeutralAnnotation) {
        guard annotation.kind == .link, let action = annotation.action else { return nil }
        let target: Target
        switch action {
        case let .goToPage(index?): target = .page(index)
        case .goToPage(nil): return nil
        case let .goToNamedDestination(name): target = .namedDestination(name)
        case let .uri(address): target = .uri(address)
        case .javaScript: target = .script
        case .launch: target = .launch
        case .remoteGoTo, .named, .other: target = .unsupported
        }
        self.init(bounds: annotation.bounds, target: target, left: annotation.destinationLeft, top: annotation.destinationTop)
    }

    /// The link under a page-space point: the smallest one when links overlap, so a detail
    /// bubble inside a larger linked area wins.
    public static func hit(_ point: CGPoint, in links: [DrawingLink]) -> DrawingLink? {
        links.filter { $0.bounds.standardized.contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// Whether a web address may be offered for opening at all: http, https and mail only.
    public static func isOpenableAddress(_ address: String) -> Bool {
        guard let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
