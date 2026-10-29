import Foundation

/// Turning a security-scoped bookmark back into a URL.
///
/// This is the one file-access operation in the bridge whose API genuinely differs between
/// platforms, so ADR-0005 §2 applies literally: the portable package states the requirement
/// and the platform tier supplies the implementation. There is no `#if os(macOS)` branch
/// here and there must never be one — on macOS the bookmark is resolved with
/// `URL.BookmarkResolutionOptions.withSecurityScope`, which does not exist on iOS, where the
/// scope instead travels inside the bookmark the document picker produced.
///
/// The conforming type only *resolves*. ``PDFKitDocumentProvider`` starts the scope with
/// `startAccessingSecurityScopedResource()` and releases it when the document closes, so the
/// resolve/start/stop triple stays bracketed in one place rather than in every caller.
///
/// A provider constructed without a resolver rejects
/// ``DocumentSource/securityScopedBookmark(_:)`` with
/// ``PDFBridgeError/bookmarkUnresolvable(reason:)``. It does not fall back to an unscoped
/// resolve: silently reading a file the sandbox did not grant is the failure mode this
/// protocol exists to prevent.
public protocol SecurityScopedBookmarkResolving: Sendable {

    /// Resolves `bookmark` to the file it names.
    ///
    /// - Throws: any error the platform's bookmark resolution raises. The provider wraps it
    ///   in ``PDFBridgeError/bookmarkUnresolvable(reason:)`` unless it is already a
    ///   ``PDFBridgeError``.
    func resolve(_ bookmark: Data) throws -> URL
}
