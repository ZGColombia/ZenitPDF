# Contributing

Contributions to Zenit PDF are welcome under the [MIT license](LICENSE).
Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Start here

Read [Building](BUILDING.md), the [architecture map](Docs/Architecture/README.md), and the
README for the package you want to change. Discuss substantial behavior or format changes
in an issue before implementing them. Describe the user's task and the expected result.

Keep changes focused. Preserve unrelated work, follow existing Swift 6 concurrency boundaries,
and keep engine code independent of AppKit. Record changes to contracts and storage behavior
in the relevant architecture decision and format documentation. Do not silently change stored
measurement values or round intermediate quantities for display.

## Tests and fixtures

Use generated synthetic fixtures from [ZPDFTestingSupport](Packages/ZPDFTestingSupport/README.md).
Do not submit private drawings, customer files, identifying screenshots, signing credentials,
or personal machine paths. A minimal generated reproduction is preferred for bugs.

Run the checks appropriate to the changed packages from [Tests](Tests/README.md), and report
exactly what ran, failed, or could not run. Bundle, UI, and package checks cover different
surfaces. Documentation-only edits need link and content checks, not an application build.

## Pull requests

Explain the problem, resulting behavior, and relevant validation. Include a regression test
when a behavior change needs one. Update user-facing documentation when appropriate, and add a
[CHANGELOG](CHANGELOG.md) entry for a user-visible change under a `## Unreleased` heading at the
top of the file, above the newest version; create that heading if it is missing. A release
renames it to the version: the release workflow requires a line that reads exactly `## X.Y.Z`
for the tagged version, suffix included for a pre-release (`## 1.2.0-beta.1`). Avoid unrelated formatting churn.

Keep public text factual and use Zenit PDF's terminology. Preserve all required upstream
license notices when adding or changing dependencies. Report security vulnerabilities privately
using [SECURITY](SECURITY.md), rather than attaching sensitive material to a public issue.
