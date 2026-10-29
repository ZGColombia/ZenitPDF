# Toolchain

| Component | Requirement |
|---|---|
| Deployment | macOS 14 or later |
| Architectures | Apple silicon (`arm64`) and Intel (`x86_64`); bundle assembly combines both |
| Xcode | Full Xcode 27.1 installation for app assembly and App Intents metadata extraction. Releases require Xcode 27.1: the release workflow fails without it. CI selects it on the GitHub runner image `xcode-27` and warns, then uses the image default, if the image lacks it |
| Swift | Swift 6 language mode; package manifests use tools version 6.0 |
| Native bridges | C/C++ compiler supplied by Xcode; vendored source under `Bridges/` |
| Dependency resolution | SwiftPM fetches GRDB at the revision in `Packages/ZPDFPersistence/Package.swift` |
| Packaging | macOS `lipo`, `codesign`, `hdiutil`, `plutil`, and `shasum` |

Select the full Xcode developer directory and finish Xcode's first-launch setup before building.
The first dependency resolution requires network access. Once dependencies are cached,
package work can reuse them; a clean offline build is not promised.

Deployment targets describe supported runtime versions, not the minimum development toolchain.
Some engine packages declare iOS portability; this is not an iPad application release.

See [Building](BUILDING.md) for commands, [Tests](Tests/README.md) for check scopes, and
[Distribution](Docs/Release/DISTRIBUTION.md) for signing and release artifacts.
