import Foundation
import UniformTypeIdentifiers

/// Identity and file-type constants, read from the bundle where the bundle has them.
///
/// The fallbacks matter: the same code runs from a `.app` and from `swift run` during development,
/// and a `nil` bundle identifier in the second case must not turn into an empty window title.
public enum ZenitAppInfo {

    /// `com.zenitgroup.zenitpdf`.
    public static let bundleIdentifier = "com.zenitgroup.zenitpdf"

    /// The product name. Not localized: it is a proper noun.
    public static let displayName = "Zenit PDF"

    /// The URL scheme the bundle registers.
    public static let urlScheme = "zenitpdf"

    /// Marketing version, from `CFBundleShortVersionString`.
    public static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Build number, from `CFBundleVersion`.
    public static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The document package type, `com.zenitgroup.zenitpdf.project`, extension `zpdfproj`.
    public static let projectTypeIdentifier = "com.zenitgroup.zenitpdf.project"

    /// The project package extension, without the dot.
    public static let projectExtension = "zpdfproj"

    /// The measurement overlay type (feature 6), declared in `Info.plist.in`.
    public static let overlayTypeIdentifier = "com.zenitgroup.zenitpdf.overlay"

    /// The measurement overlay extension, without the dot.
    public static let overlayExtension = "zpdfoverlay"

    /// The `UTType` for a measurement overlay: the declared type when the bundle exports it,
    /// never a session-local `dyn.*` type (the LT-22 failure mode).
    public static var overlayType: UTType {
        if let declared = UTType(overlayTypeIdentifier), declared.isDeclared { return declared }
        return UTType(filenameExtension: overlayExtension, conformingTo: .json) ?? .json
    }

    /// The `UTType` for a Zenit project package, declared by the bundle when running from one and
    /// constructed from the identifier otherwise.
    public static var projectType: UTType {
        UTType(projectTypeIdentifier)
            ?? UTType(exportedAs: projectTypeIdentifier, conformingTo: .package)
    }
}
