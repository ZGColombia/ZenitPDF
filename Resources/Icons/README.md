# Icons

`AppIcon.svg` is the source artwork. `AppIcon.icns`, `ProjectDocument.icns`, and
`AppIcon.appiconset` contain the generated macOS application and project-document icons.

Change the source artwork and generator together, then run `Scripts/generate-app-icon.sh`
from the repository root. Do not hand-edit generated raster representations.

Application bundle assembly copies the icons from this folder. Preserve artwork provenance
and avoid introducing third-party assets without their required notices. See
[Building](../../BUILDING.md) and [Licensing](../../Docs/Legal/LICENSING_STATEMENT.md).
