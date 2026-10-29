# Tests and verification

Tests use generated synthetic fixtures, principally [ZPDFTestingSupport](../Packages/ZPDFTestingSupport/README.md).
No private drawings are required or published. Use isolated temporary directories for projects,
preferences, and fixture output; clean up crash-recovery markers and helper processes.

## Tiers

| Tier | What it covers | Runner from repository root |
|---|---|---|
| Domain | Contracts/freeze drift, geometry, formulas, measurement calculations, ledger, golden measurements | `Scripts/build-core-packages.sh` |
| UI packages | Presentation, design system, ledger, measurement, workflows, shell; design audit and hosted targets | `Scripts/build-ui-packages.sh` |
| Document I/O | Generated fixtures, extraction, PDFKit, persistence, compare, search, service client | `Scripts/build-io-packages.sh` |
| Coordination | Engine-backed presenters and workflow state | `Scripts/build-appcore-package.sh` |
| App package | AppKit integration tests, modal guardrails, watchdog, and executed-test accounting; needs the bundle from `Scripts/build-app.sh` first | `Scripts/build-app-package.sh` |
| Snap | Snap package build and tests | `Scripts/build-snap-package.sh` |
| Rendering | Renderer build and tests | `Scripts/build-renderer-package.sh` |
| Platform | Image intake, DXF, spreadsheets, collaboration, CLI, and Quick Look package tests | `Scripts/build-platform-packages.sh` |
| Native PDF bridge | qpdf bridge build and tests | `Scripts/build-qpdf-bridge.sh` |
| Core workflow | Generated drawing through calibration, measurement, save/reopen, and export | `Scripts/acceptance-core-loop.sh` |
| Assembled app | Universal bundle, resources, helper wiring, signing, and bundle gates | `Scripts/build-app.sh` |

`Tests/GoldenMeasurements` contains numeric acceptance cases. `Tests/CoreLoop` exercises the
cross-package takeoff flow. Most unit tests live under each package's own `Tests` directory.
Package tests do not prove Finder registration, a successful app launch, or live accessibility.

## Verification scripts

| Script | Checks |
|---|---|
| `verify-app-launches.sh` | Launches the assembled app, checks responsiveness, quits it, and checks cleanup. |
| `verify-bundle-linkage.sh` | Bundle dependency/load paths and helper linkage, to catch launch-time loader failures. |
| `verify-export.sh` | Export/bridge build and tests, and excluded native dependency symbols. |
| `verify-hook-wiring.sh` | Declared presenter/shell hooks have assignments. |
| `verify-hosted-hit-targets.sh` | Transparent interactive controls and hosted inspector hit targets. |
| `verify-licence-notices.sh` | Shipped component inventory, license resources, and bundle notice consistency. |
| `verify-localization.sh` | Localization key coverage, format placeholders, and safety of language catalogs; the shipped interface remains English only. |
| `verify-multiplatform.sh` | Portable packages build for an iOS destination and avoid AppKit/UIKit dependencies; does not validate an iPad app. |
| `verify-no-armed-recovery-markers.sh` | No project package under the repository is left with its crash-recovery marker armed. With `ZENIT_ARMED_SCAN_HOME=1` it also searches `~/Documents`, `~/Desktop` and `~/Downloads`, which may prompt for macOS Files and Folders access and exits 75 if a folder cannot be read. |
| `verify-no-uninjected-modals.sh` | App dialogues route through the injectable modal presenter. |
| `verify-no-competitor-names.sh` | Restricted product-name patterns are absent from package, app, bridge and tool sources and tests, `Tests/`, `Resources/`, the frozen contracts, `Scripts/`, `.github/`, the top-level documents, the package manifests and documents, `Docs/`, `Packaging/`, and the assembled bundle when one is present. `ExternalResearch/` is not scanned. |
| `verify-author-scrub.sh` | Names supplied at run time (`ZENIT_SCRUB_NAMES`, a CI secret of the same name, or with `ZENIT_SCRUB_SELF=1` the running account's full name) are absent from every publishable file, binary files included; the names themselves are never stored in the repository. With no names it prints `SKIPPED` locally; in CI it fails on the project's own repository and warns on a fork. See [Building](../BUILDING.md#optional-gate-settings). |
| `verify-no-network.sh` | The assembled bundle has no network capability: no networking entitlement, no imported network entry point, no updater key in `Info.plist`, and no embedded updater. Inspects files only; launches nothing. |
| `verify-snap-search-compare.sh` | Snap, search, and comparison build/test gates and associated adversarial checks. |
| `verify-test-tier-hygiene.sh` | Test isolation and prohibited shared process/machine state; runs the app suite, so it needs the bundle from `Scripts/build-app.sh` first. |
| `verify-viewer-budgets.sh` | Optimized viewer timing tests against committed budgets. |

Scripts are under `Scripts/`; read their usage before invoking a gate that requires an assembled
bundle. `fuzz-harness.sh` runs a selected prebuilt test filter in a bounded subprocess;
`automation-benchmark.sh` runs the synthetic automation benchmark.
`make-dmg.sh` verifies the signed input bundle, disk image, and generated checksum.

## Reporting results

Record the source revision, command, configuration, and actual result. Count executed tests
from runner output, not merely declarations. Report missing tools, skipped cases, unavailable
services, and unrun UI checks explicitly. Do not turn an unrun check into a pass.
Performance budgets are requirements; reading their values is not a benchmark result.
See [QUALITY_BAR](../Docs/Execution/QUALITY_BAR.md) and [Building](../BUILDING.md).
