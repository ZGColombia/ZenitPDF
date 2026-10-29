# Building Zenit PDF

## Prerequisites

Use macOS with a full Xcode 27.1 installation selected as the active developer directory.
Command Line Tools alone are insufficient for assembling the application: the build uses
Xcode's App Intents metadata processor and extension tooling. Packages use Swift 6 language
mode and a macOS 14 deployment target. See [Toolchain](TOOLCHAIN.md).

Install Xcode, complete its first-launch setup and license acceptance, and select it with
`xcode-select` if necessary. Check `xcode-select -p`, `xcodebuild -version`, and `swift --version`
when diagnosing toolchain selection.

Clone this repository, then run commands from its root. SwiftPM fetches the pinned GRDB
revision on the first build, so that build needs network access. Native bridge source is
vendored in the repository. The finished application itself makes no network connections.

## Build a runnable application

```sh
Scripts/build-app.sh
open "build/Zenit PDF.app"
```

The script builds release slices for `arm64` and `x86_64`, combines them into universal
binaries, assembles resources, the command-line tool, Quick Look extensions and XPC services,
and signs the result ad hoc with its entitlements. No signing certificate is required.
The default output is `build/Zenit PDF.app`; the build directory may point to `build.noindex`.

The script also runs bundle checks. A successful signature check does not imply notarization.
No Developer ID or notarization is used, so a copy that macOS has quarantined (one that was
downloaded) needs a confirmation on first launch. On macOS 15 and later, right-click → Open no
longer bypasses the block: try to open the app once, then use System Settings → Privacy &
Security → Open Anyway. On macOS 14, right-click → Open still works. See
[Installing](Docs/INSTALL.md#opening-zenit-pdf-the-first-time) for the exact steps.

Options include `--output DIR`, `--short-version X.Y.Z`, `--build-version N`, and
`--scratch-path NAME`. Keep separate scratch directories for independent builds. The script
joins `--scratch-path` to each package's directory, so pass a relative name beginning with
`.build-` (for example `.build-release`), which `.gitignore` covers, never an absolute path.
`--skip-verify` skips the script's verification stage and must not be treated as a verified release.

## Package checks

| Command | Scope |
|---|---|
| `Scripts/build-core-packages.sh` | Contracts, geometry, formulas, measurements, ledger, and golden measurement tests; compares generated contracts with the committed freeze. |
| `Scripts/build-ui-packages.sh` | Six UI packages in dependency order, test accounting, design audit, and hosted hit-target checks. |
| `Scripts/build-io-packages.sh` | Synthetic fixtures, vector extraction, PDFKit bridge, persistence, comparison, search, and service client; includes persistence performance checks. |
| `Scripts/build-app-package.sh` | Resolves the app package, builds tests, runs them with a watchdog and checks executed test counts; also checks modal injection, armed crash-recovery markers in the repository, and related app guardrails. Run `Scripts/build-app.sh` first: one test reads the assembled bundle's licence notices, and the script stops if `build/Zenit PDF.app` is missing or older than them. |

These scripts build and test packages; they do not replace running the assembled application.
The full check inventory is in [Tests](Tests/README.md). Generated fixtures live in
[ZPDFTestingSupport](Packages/ZPDFTestingSupport/README.md); private drawings are unnecessary.

## Optional gate settings

Two gates read the local machine only when asked to, and two settings give a slower machine
more room:

| Variable | Gate | Effect |
|---|---|---|
| `ZENIT_SCRUB_NAMES` | `Scripts/verify-author-scrub.sh` | Names to keep out of the repository, separated by commas or newlines. Every word of three or more letters is matched as a case-insensitive substring across the publishable files, binary files included; offenders are printed as `file:line` only. In CI this is a repository secret. |
| `ZENIT_SCRUB_SELF=1` | `Scripts/verify-author-scrub.sh` | When `ZENIT_SCRUB_NAMES` is unset, checks the full name of the macOS account running the gate. Without either variable the gate prints `SKIPPED` and exits 0. |
| `ZENIT_ARMED_SCAN_HOME=1` | `Scripts/verify-no-armed-recovery-markers.sh` (also run by `Scripts/build-app-package.sh`) | Also searches `~/Documents`, `~/Desktop` and `~/Downloads` for project packages with an armed crash marker. The first run may make macOS ask the terminal for Files and Folders access; a folder it cannot read ends the gate with exit 75. By default only the repository is searched. |
| `ZENIT_TEST_TIMEOUT_SECONDS` | `Scripts/build-app-package.sh` | Absolute cap on the app suite's run, default 3600 s; the suite takes about 1300 s on the reference Mac. A separate 300 s no-progress watchdog catches a hung suite either way. CI sets 6000. |
| `ZENIT_TIMING_ADVISORY=1` | The viewer's millisecond budgets in the app package suite, and the ledger's concurrent-versus-serial check (IM-081) in the core packages | Reports a miss in those checks as a warning instead of a failure. Every other timing assertion stays blocking. CI sets it on its hosted runners. `Scripts/verify-viewer-budgets.sh` ignores it. |

## Package a disk image

```sh
Scripts/make-dmg.sh "build/Zenit PDF.app" dist
```

This verifies the app signature, stages the app and an Applications shortcut, creates and
verifies a compressed disk image, and writes `dist/SHA256SUMS.txt`. The image is not
byte-reproducible because packaging includes timestamps. Checksums identify the distributed
artifact, not an independently rebuilt binary.

Maintainer signing uses `ZENIT_RELEASE_SIGNING=1`; the private certificate and pinned
designated requirement are enforced only in that mode. It is a local option and is never used
for published releases, which `.github/workflows/release.yml` signs ad-hoc. See
[Distribution](Docs/Release/DISTRIBUTION.md).
