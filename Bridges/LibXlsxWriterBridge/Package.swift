// swift-tools-version:6.0
import PackageDescription

/// `LibXlsxWriterBridge` vendors libxlsxwriter (BSD-2-Clause) as a plain SwiftPM C target and
/// wraps it in a Swift API, the same way `Bridges/Clipper2Bridge` vendors Clipper2.
///
/// Three build flags are frozen here, and each one removes a bundled component — and therefore
/// a third-party licence — from the shipped binary. This package decides them; the decision
/// record is conflict 3 in `Docs/Licences/LICENSE_EVIDENCE.md`:
///
/// - `USE_STANDARD_TMPFILE` — the C standard `tmpfile()` is used and the MPL-2.0 `tmpfileplus`
///   component is not vendored, not compiled and not linked. MPL-2.0 was the only copyleft
///   licence anywhere in the dependency set; excluding the component removes the §3.2
///   source-availability obligation instead of managing it on every release forever.
/// - `USE_NO_MD5` — the Openwall MD5 implementation is only used to de-duplicate *images*
///   embedded in a worksheet. This bridge writes no images, so the component is not vendored.
/// - `USE_DTOA_LIBRARY` is **not** defined, so `emyg_dtoa` is not vendored either;
///   libxlsxwriter falls back to a bare `%.16G` (`lxw_sprintf_dbl`), which is *not* locale-guarded;
///   the Swift wrapper pins the thread numeric locale to "C" for the whole workbook write, which
///   covers every call that formats a number (`withCNumericLocale`, BH-403).
///
/// What remains from upstream `third_party/` is minizip (zlib licence) plus the `queue.h` and
/// `tree.h` macro headers (FreeBSD). zlib itself is the system library.
let package = Package(
    name: "LibXlsxWriterBridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFXlsxWriter", targets: ["ZPDFXlsxWriter"])
    ],
    targets: [
        .target(
            name: "CXlsxWriter",
            path: "Sources/CXlsxWriter",
            sources: ["src", "minizip"],
            publicHeadersPath: "include",
            cSettings: [
                // Excludes the MPL-2.0 tmpfileplus component entirely (see above).
                .define("USE_STANDARD_TMPFILE"),
                // Excludes the bundled MD5; only used for worksheet image de-duplication.
                .define("USE_NO_MD5")
            ],
            linkerSettings: [
                // System zlib. minizip's deflate comes from here, not from a vendored copy.
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "ZPDFXlsxWriter",
            dependencies: ["CXlsxWriter"],
            path: "Sources/ZPDFXlsxWriter",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFXlsxWriterTests",
            dependencies: ["ZPDFXlsxWriter"],
            path: "Tests/ZPDFXlsxWriterTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
