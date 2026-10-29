// swift-tools-version:6.0
import PackageDescription

/// `QPDFBridge` vendors qpdf (Apache-2.0) as a SwiftPM C++ target and exposes a
/// Swift API for PDF repair and structural operations.
///
/// Two hard constraints shape this manifest, both documented in `VENDORED.md`:
///
/// 1. **Crypto provider.** qpdf's CMake defaults `USE_IMPLICIT_CRYPTO=ON`, which
///    prefers GnuTLS (LGPL-2.1-or-later) when it happens to be installed. There is
///    no CMake here, so the choice is static: only the native crypto sources are
///    vendored and only `USE_CRYPTO_NATIVE` is defined. The GnuTLS and OpenSSL
///    providers are absent from the source tree entirely — headers included.
/// 2. **No libjpeg.** macOS ships no public libjpeg and no permissively licensed
///    libjpeg source is available offline, so `Pl_DCT.cc` is not vendored and
///    `ZPDF_QPDF_NO_DCT` disables the `/DCTDecode` stream-filter registration.
///    DCT-encoded image streams are then simply not *filterable*, which is the
///    same state qpdf uses for `/CCITTFaxDecode` and `/JPXDecode`: they are copied
///    through byte-for-byte. `DCTPassthroughTests` proves that.
let package = Package(
    name: "QPDFBridge",
    // ADR-0005: QPDFBridge is portable tier. iOS 17 is a compile target enforced by
    // Scripts/verify-multiplatform.sh, not a support claim — no iOS product ships.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFQPDF", targets: ["ZPDFQPDF"])
    ],
    dependencies: [
        .package(path: "../../Packages/ZPDFTestingSupport")
    ],
    targets: [
        // Vendored qpdf plus a hand-written extern "C" shim. The only public
        // header is include/zpdf_qpdf.h, which contains no C++, so the Swift side
        // imports a plain C module and no Swift/C++ interop is required anywhere
        // in Zenit PDF.
        .target(
            name: "CQPDF",
            path: "Sources/CQPDF",
            sources: ["src", "upstream/libqpdf"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/libqpdf"),
                // sph (the bundled sphlib SHA-2) lives outside the compiled
                // source directory because `sha2.c` #includes `sph/md_helper.c`
                // as a header; SwiftPM would otherwise compile it as its own
                // translation unit and produce duplicate symbols.
                .headerSearchPath("upstream/sphinclude")
            ],
            cxxSettings: [
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/libqpdf"),
                .headerSearchPath("upstream/sphinclude"),
                // qpdf builds its own object files with this defined; it only
                // affects __declspec on Windows but keeps the sources on the
                // path upstream compiles.
                .define("libqpdf_EXPORTS"),
                // No libjpeg: see the note above and VENDORED.md.
                .define("ZPDF_QPDF_NO_DCT")
            ],
            linkerSettings: [
                // zlib is part of the macOS SDK (libz.tbd). Pl_Flate.cc needs it.
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "ZPDFQPDF",
            dependencies: ["CQPDF"],
            path: "Sources/ZPDFQPDF",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFQPDFTests",
            dependencies: [
                "ZPDFQPDF",
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            path: "Tests/ZPDFQPDFTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    cxxLanguageStandard: .cxx20
)
