// swift-tools-version:6.0
import PackageDescription

/// Finder thumbnails for Zenit PDF projects (NL-PLAT-21): a Quick Look thumbnail extension.
///
/// `Scripts/build-app.sh` builds `ZenitQuickLook` and wraps it into
/// `Zenit PDF.app/Contents/PlugIns/ZenitQuickLook.appex`, sandboxed, with no entitlement beyond the
/// sandbox: Quick Look hands the extension the one package it is asked about. Everything the
/// extension does lives in `ZenitQuickLookCore`, where the tests are; the executable is the
/// provider class and the extension entry point.
///
/// A project's thumbnail is the picture the application saved into the package
/// (`thumbnails/package.png`) when there is one; otherwise the extension draws the first sheet of
/// the package's drawing with CoreGraphics, inside its own sandboxed process.
///
/// `ZenitQuickLookPreview` is the Space-bar preview, wrapped the same way into
/// `Contents/PlugIns/ZenitQuickLookPreview.appex`: the first sheet with its markups and the
/// ledger's grand totals, from `thumbnails/preview.png` and `thumbnails/summary.json`, which the
/// application writes after each save (`PackagePreview`, `PackagePreviewSummary`).
let package = Package(
    name: "QuickLookThumbnail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZenitQuickLook", targets: ["ZenitQuickLook"]),
        .executable(name: "ZenitQuickLookPreview", targets: ["ZenitQuickLookPreview"]),
        .library(name: "ZenitQuickLookCore", targets: ["ZenitQuickLookCore"])
    ],
    targets: [
        .target(
            name: "ZenitQuickLookCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ZenitQuickLook",
            dependencies: ["ZenitQuickLookCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                // An app extension starts in Foundation's extension main, which loads the principal
                // class Info.plist names; the executable's own `main` is never called.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])
            ]
        ),
        // NL-PLAT-21: the Space-bar preview — the first sheet with its markups and the ledger's
        // grand totals — as a data-based Quick Look preview extension.
        .executableTarget(
            name: "ZenitQuickLookPreview",
            dependencies: ["ZenitQuickLookCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])
            ]
        ),
        .testTarget(
            name: "ZenitQuickLookCoreTests",
            dependencies: ["ZenitQuickLookCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
