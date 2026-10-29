# The `.zpdfproj` project package and Zenit's open file formats

Zenit PDF keeps a takeoff in a project package and exchanges data through a handful of JSON
files. This folder publishes what is stable and what is not.

## What is a public contract

The JSON formats below are public. Each has a JSON Schema (draft 2020-12) in this folder, and a
test in `Tools/ZenitCLI/Tests/ZenitCLITests/FormatSchemaConformanceTests.swift` validates every
exporter's real output against its schema and imports a hand-written minimal file per schema, so a
format cannot drift from its published description without a test failing.

| File | Schema | What it holds | Can it change a takeoff? |
|---|---|---|---|
| `.zpdfjson` | `zpdfjson.schema.json` | The Quantity Ledger: columns, rows, groups, totals. Numbers carry the exact stored value (`raw`, SI units) and the text the ledger shows (`display`). | No. It carries no geometry; import reviews and reconciles it. |
| `.zpdfoverlay` | `zpdfoverlay.schema.json` | The measurements of one drawing with their geometry, for another copy of the same drawing (identified by SHA-256). | Yes, after a review, and only onto the same drawing. |
| `.zpdftools` | `zpdftools.schema.json` | Tool Library presets. | Adds tools after a review; never a markup, never a scale. |
| `.zpdftemplate` | `zpdftemplate.schema.json` | A job template: presets, subjects, column preferences, units, optional export profiles, with a SHA-256 of its content. | Sets up a project's tools; it cannot carry a scale. |
| `.zpdfprofile` | `zpdfprofile.schema.json` | How the ledger is written for a receiving system's CSV import. | No. |
| `.zpdfpack` | `zpdfpack.schema.json` (its `pack.json`) | A zip of tool sets, templates and profiles. | Only through the importers of those three formats. Nothing in a pack runs. |

All of them are data. None is executed, followed or resolved; every importer treats its file as
untrusted, bounds its size and its values before believing anything, and refuses a newer format
version by number instead of guessing.

Each schema's `$id` lies under `https://zenitgroup.com.co/schemas/` and ends in its version, for
example `https://zenitgroup.com.co/schemas/zpdfjson/1`. An `$id` names a schema; nothing fetches it.

A review exported as XFDF (ISO 19444-1) adds a `zenit:drawing` element with the drawing's SHA-256,
when it is known, and a `zenit:status` attribute on each markup, in the namespace
`https://zenitgroup.com.co/ns/zenit-review/1`; other XFDF readers ignore them. The importer
matches the `zenit:` prefix, not the namespace URI, so a file written under an earlier URI still
imports.

## What is private

The **project package** is Zenit PDF's own storage. Its layout is documented here so people can
back it up, send it and inspect it, but its SQLite schema is **private**: the schema version is
Zenit's to change in any release (every change is a forward migration that keeps old projects
opening), and nothing outside Zenit PDF should read or write `project.sqlite` directly. To get data
out, export one of the formats above, or use the read-only `zenit` command-line tool
(`zenit totals`, `zenit export --format csv|xlsx|json`, `zenit info`, `zenit verify`), which reads
a private copy of the package and never writes to it. `totals`, `export` and `info` refuse, with
exit code 1, a project that `zenit verify` fails, unless `--allow-unverified` is given; the
problems are then named on standard error.

```text
Project.zpdfproj/
├── manifest.json          what the package is: format, schema version, display name, digests
├── integrity.json         SHA-256 of the manifest and the database, and the save token
├── project.sqlite         the takeoff (private schema; see above)
├── documents/
│   ├── original.pdf       the drawing as it arrived, never modified
│   ├── working.pdf        the drawing Zenit works on
│   └── revisions/         earlier and later revisions of the drawing
├── attachments/           photos, the original image of a scanned sheet, other attached files
├── thumbnails/           package.png: the first sheet as last saved, for Finder (optional; the Quick
│                          Look extension draws documents/working.pdf when it is absent)
├── ocr/                   recognised text of scanned sheets (only when the person runs recognition)
├── geometry/
├── reports/
├── toolsets/
├── recovery/              this machine's session: journal, last good manifest, crash marker,
│                          autosave — never sent (File ▸ Send Project… leaves it out)
├── versions/              the last completed saves (latest, previous)
└── licences/
```

Shared Review uses files in a folder selected by the user. A separate sync service may
transport that folder; Zenit PDF itself makes no network connections. See the
[privacy policy](../Legal/PRIVACY.md) and the
[shared review decision](../Architecture/ADR/ADR-0026-collaboration-shared-review-folder.md).
Use [the CLI](../../Tools/ZenitCLI/README.md) or supported exports for programmatic access.
