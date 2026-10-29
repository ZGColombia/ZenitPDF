// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipper2Bridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFClipper2", targets: ["ZPDFClipper2"])
    ],
    targets: [
        // Vendored Clipper2 (Boost Software License 1.0) plus a hand-written
        // extern "C" shim. The only public header is include/zpdf_clipper2.h,
        // which contains no C++ — so no Swift/C++ interop is required anywhere.
        .target(
            name: "CClipper2",
            path: "Sources/CClipper2",
            // The shim calls the boolean engine and nothing else: offsetting, RectClip and
            // triangulation are vendored byte for byte (VENDORED.md) but not compiled (W-092).
            // `clipper.h` still includes their headers; its inline wrappers are emitted only
            // where they are called, and nothing calls them.
            exclude: ["src/clipper.offset.cpp", "src/clipper.rectclip.cpp", "src/clipper.triangulation.cpp"],
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                // Makes `#include "clipper2/clipper.h"` resolve to the vendored
                // private headers in Sources/CClipper2/clipper2/.
                .headerSearchPath("."),
                .define("CLIPPER2_MAX_DECIMAL_PRECISION", to: "8"),
                // Compiles the allocation-failure seam the shim's boundary tests drive
                // (`zpclipper2_testing_fail_allocation_after`). Debug only: it is declared in
                // no header, reached from the tests by symbol name, and absent from a release
                // build of the library, so it never enters the app bundle.
                .define("ZPCLIPPER2_TESTING_HOOKS", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "ZPDFClipper2",
            dependencies: ["CClipper2"],
            path: "Sources/ZPDFClipper2",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Depends on the C shim as well as the Swift facade: the boundary tests call the
        // extern "C" entry points directly with buffers the Swift facade would never produce.
        .testTarget(
            name: "ZPDFClipper2Tests",
            dependencies: ["ZPDFClipper2", "CClipper2"],
            path: "Tests/ZPDFClipper2Tests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    cxxLanguageStandard: .cxx17
)
