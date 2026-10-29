// swift-tools-version:6.0
import PackageDescription

/// `ZPDFSearch` is everything the user means by "find it": the FTS5 index, the on-device
/// OCR that fills the index for scanned sheets, and one ranked query surface over both.
///
/// Three rules shape the package.
///
/// 1. **Nothing leaves the machine.** Spec 17.4 is not a preference. The only recogniser
///    is `Vision`, running locally; there is no networking framework in the dependency
///    graph and `NetworkAbsenceTests` proves it by reading the linked symbols of the
///    built objects rather than by trusting this comment.
/// 2. **The schema is frozen.** `search_fts` and `ocr_token` are spec 8.2 statements,
///    owned by `ZPDFPersistence`. This package writes into them and adds no table of its
///    own — the incremental-reindex bookkeeping lives in an `index-stamp` row of the FTS
///    table itself (see ``TextIndexer``) precisely so that no migration is needed.
/// 3. **A query string is untrusted input.** Everything a user types is recompiled into
///    an FTS5 expression built only from tokens this package extracted itself, so a
///    quote, a `NEAR`, an unbalanced paren or a lone `*` is data, never syntax.
let package = Package(
    name: "ZPDFSearch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFSearch", targets: ["ZPDFSearch"])
    ],
    dependencies: [
        .package(path: "../ZPDFPersistence"),
        .package(path: "../ZPDFPDFKitBridge"),
        // Test-only. The library target never sees the fixture corpus.
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFSearch",
            dependencies: [
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFSearchTests",
            dependencies: [
                "ZPDFSearch",
                .product(name: "ZPDFPersistence", package: "ZPDFPersistence"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
