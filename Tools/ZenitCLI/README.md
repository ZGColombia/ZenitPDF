# zenit command-line tool

Read-only project inspection and ledger export. Every command leaves the source `.zpdfproj`
package unchanged. The reader uses a private working copy for database access.

## Run

The assembled app includes `Contents/Helpers/zenit`. The sandboxed app cannot add it to your
`PATH` itself; **Settings ▸ Command-Line Tool** shows the line that links it from where the app
is installed. For an app in Applications:

```sh
sudo ln -sf '/Applications/Zenit PDF.app/Contents/Helpers/zenit' /usr/local/bin/zenit
```

The tool is signed with Hardened Runtime and no entitlements, so it runs unsandboxed in your
own Terminal session, on the paths you give it.

For development, from the repository root:

```sh
swift run --package-path Tools/ZenitCLI zenit info "Project.zpdfproj"
```

Replace `Project.zpdfproj` with your project path. Commands implemented by the executable:

```text
zenit info   <Project.zpdfproj> [--allow-unverified]
zenit verify <Project.zpdfproj>
zenit totals <Project.zpdfproj> [--json] [--allow-unverified]
zenit export <Project.zpdfproj> --format csv|xlsx|json --output <file> [--allow-unverified]
```

`info` prints the project name and drawing/page/markup/scale counts. `verify` checks package
integrity and reports whether the last session closed cleanly. `totals` prints ledger totals;
`--json` requests structured output. `export` writes the selected ledger format to the output
path, without changing the project itself.

`info`, `totals`, and `export` refuse a project that fails verification unless
`--allow-unverified` is supplied. That option reports problems on standard error and permits
reading; it does not repair the package or make the resulting quantities trustworthy.

Exit codes: **0** success, **1** read/verification failure, **2** invalid usage.
Calling without a command and project prints usage and exits 2; no separate help command
is implemented.

See [formats](../../Docs/Formats/zpdfproj.md), [Building](../../BUILDING.md), and
[test tiers](../../Tests/README.md).
