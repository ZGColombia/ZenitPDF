# Homebrew cask (template)

`zenit-pdf.rb` is a Homebrew cask for Zenit PDF, kept here as a template. **It is not
published.** No tap exists yet, so `brew install` cannot find Zenit PDF, and no document may
say that it can until the steps below have been done and tested. The supported ways to install
are in [Docs/INSTALL.md](../../Docs/INSTALL.md).

The cask installs the universal disk image from a GitHub release, checks it against the
`sha256` in the cask, removes the quarantine flag from the installed app only (the same thing
`Scripts/install.sh` does after its own checksum check), and lists Zenit PDF's own data for
`brew uninstall --zap`.

## Publish a tap (once)

A tap is a GitHub repository named `homebrew-<something>`. With the tap below, people install
with `brew install --cask zgcolombia/tap/zenit-pdf`.

1. Create a public repository `ZGColombia/homebrew-tap` with a `Casks/` folder.
2. After the first release is published, fill in the cask for it and copy it into the tap:

   ```sh
   Scripts/update-cask.sh 1.0.0 --cask ../homebrew-tap/Casks/zenit-pdf.rb
   ```

   (Copy `Packaging/homebrew/zenit-pdf.rb` to `../homebrew-tap/Casks/` first; the script
   rewrites only the `version` and `sha256` lines of the file it is given.)
3. Commit and push the tap, then check it from a clean shell:

   ```sh
   brew tap zgcolombia/tap
   brew audit --cask --online zgcolombia/tap/zenit-pdf
   brew install --cask zgcolombia/tap/zenit-pdf
   brew uninstall --cask zgcolombia/tap/zenit-pdf
   ```

4. Only now add the `brew install --cask zgcolombia/tap/zenit-pdf` line to `Docs/INSTALL.md`
   and remove "No Homebrew cask" from `Docs/KNOWN_LIMITATIONS.md`.

## Every release

```sh
Scripts/update-cask.sh X.Y.Z --cask ../homebrew-tap/Casks/zenit-pdf.rb
```

Without `--sums` the script downloads `SHA256SUMS.txt` from the `vX.Y.Z` release on GitHub and
takes the line for `ZenitPDF-X.Y.Z-universal.dmg`, which is the file the cask's `url` names.
With `--sums dist/SHA256SUMS.txt` it reads a local file instead; use that only when the local
file is the one that was uploaded, because the disk image is not byte-reproducible and a
rebuilt image has a different checksum. Pre-release versions are refused: the cask should offer
the newest stable release.

Then commit and push the tap. `brew upgrade` picks the new version up from there.

To keep this repository's template current as well, run the script without `--cask`; it then
rewrites `Packaging/homebrew/zenit-pdf.rb`.
