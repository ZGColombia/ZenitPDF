# Zenit PDF application

The macOS 14+ AppKit application composes the UI packages and engine-backed presenters.
`Sources/ZenitPDF` contains the executable entry and App Intents; `Sources/ZenitPDFAppKit`
contains document/window controllers, canvas integration, menus, platform workflows, and
adapters. `Bundle` holds bundle metadata, entitlements, and shipped license resources.

Run `Scripts/build-app.sh` from the repository root to assemble the universal application,
XPC helpers, CLI, and Quick Look extensions. Full Xcode 27.1 is needed for assembly; no
certificate is needed for the default ad-hoc build. Then run `Scripts/build-app-package.sh` to
build and test the package: one test reads the assembled bundle's licence notices, so the
script stops if `build/Zenit PDF.app` is missing or older than them. See
[Building](../../BUILDING.md).

PDFKit processing remains in this process. Geometry and repair helpers have the narrower
boundaries in the [architecture map](../../Docs/Architecture/README.md).
The interface ships in English, with locale-aware number formatting. The app makes no
network connections and has no update feature.
