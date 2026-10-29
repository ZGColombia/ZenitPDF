# Installing Zenit PDF

Zenit PDF runs on **macOS 14 Sonoma, macOS 15 Sequoia and macOS 26 Tahoe**, on Apple silicon
and Intel Macs. Installing needs about 400 MB of free disk space; the installed app uses about
300 MB. The internet is needed only to download it: the app itself makes no network connections.

To see which macOS you have, choose **Apple menu > About This Mac**.

There are three ways to install. All three give you the same app.

| Way | Good for | Security question on first launch |
| --- | --- | --- |
| [One line in Terminal](#1-one-line-in-terminal-recommended) | everyone; also the easiest way to update | none |
| [Disk image](#2-disk-image) | people who prefer to click | once |
| [Zip](#3-zip) | people who prefer a zip file | once |

There is no App Store version and no published Homebrew cask yet
([Packaging/homebrew](../Packaging/homebrew) holds a template for one).

## 1. One line in Terminal (recommended)

1. Open **Terminal**: press **Command-Space**, type *Terminal*, and press **Return**.
2. Paste this line and press **Return**:

   ```sh
   curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash
   ```

3. Wait for **Zenit PDF … is installed.** Then open Zenit PDF from the Applications folder or
   Spotlight. macOS does not ask any security question.

What the installer does:

- checks that the Mac runs macOS 14 or later;
- downloads the newest release from GitHub, with its list of checksums;
- refuses to continue unless the download's SHA-256 checksum matches the published one;
- opens the disk image hidden and read-only, checks the app's code signature, and copies it to
  **Applications**;
- removes the macOS "downloaded from the internet" flag from that one app, which is why no
  security question appears;
- prints where the app is and how to uninstall it.

It never asks for an administrator password, never uses `sudo`, and sends nothing anywhere.

Questions it may ask (type **y** and press **Return** for yes):

- **"Quit Zenit PDF now?"** Zenit PDF is open and has to close before it can be replaced. Answer
  yes and Zenit PDF quits normally, asking you to save unsaved changes first. Answer no and
  nothing changes. The installer never force-quits the app.
- **"Install Zenit PDF just for you, in your own Applications folder?"** Your user account is not
  allowed to add apps to the main Applications folder (it is not an administrator account).
  Answer yes to install into the Applications folder inside your home folder. It works the same.

### Options

Add options after `bash -s --`:

```sh
# a particular version
curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash -s -- --version 1.0.0

# another folder
curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash -s -- --dest ~/Applications

# show what would happen, change nothing
curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash -s -- --dry-run
```

`--yes` answers yes to the questions above. `--dmg PATH` installs from a disk image you already
downloaded, with no network; a `SHA256SUMS.txt` next to it is checked. `--help` lists everything.

### Read it before you run it

Pasting a command from a web page runs a program on your Mac, so it is reasonable to look first.
The installer is one readable file, [Scripts/install.sh](../Scripts/install.sh). To download it,
read it and then run it:

```sh
curl -fsSLO https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh
open -e install.sh        # opens it in TextEdit
bash install.sh
```

## 2. Disk image

1. Open the [newest release](https://github.com/ZGColombia/ZenitPDF/releases/latest) and click
   **ZenitPDF-*version*-universal.dmg** under **Assets**.
2. Double-click the downloaded file in your Downloads folder. A window opens with **Zenit PDF**,
   a shortcut to **Applications**, and the note **How to open Zenit PDF the first time**.
3. Drag **Zenit PDF** onto **Applications**.
4. Eject the disk image: click the eject button next to **Zenit PDF** in the Finder sidebar.
5. Open the app as described in [Opening Zenit PDF the first time](#opening-zenit-pdf-the-first-time).

## 3. Zip

1. On the [newest release](https://github.com/ZGColombia/ZenitPDF/releases/latest), click
   **ZenitPDF-*version*-universal.zip** under **Assets**.
2. Double-click the downloaded zip. **Zenit PDF** appears next to it.
3. Drag **Zenit PDF** into the **Applications** folder.
4. Open the app as described in the next section.

## Opening Zenit PDF the first time

This applies to the disk image and the zip, not to the one-line installer.

Zenit PDF is free, open-source software. It is not signed with an Apple Developer ID and not
notarized by Apple, so macOS asks you to confirm the first time you open a downloaded copy. You
do this once per downloaded copy. Do not turn off Gatekeeper for the whole Mac; it is not needed.

### macOS 15 Sequoia and macOS 26 Tahoe

1. Open the **Applications** folder and double-click **Zenit PDF**.
   macOS shows **"Zenit PDF" Not Opened** and *Apple could not verify "Zenit PDF" is free of
   malware that may harm your Mac or compromise your privacy.* Click **Done**, not
   **Move to Trash**.
2. Choose **Apple menu > System Settings**, then click **Privacy & Security** in the sidebar.
3. Scroll down to **Security**. Next to *"Zenit PDF" was blocked to protect your Mac.* click
   **Open Anyway**.
4. macOS asks you to confirm. Click **Open Anyway**, and enter your Mac login password or use
   Touch ID when asked.

Zenit PDF opens. The **Open Anyway** button appears only for about an hour after you tried to
open the app; if you do not see it, do step 1 again. Control-click > Open does not skip these
steps on macOS 15 and later.

### macOS 14 Sonoma

1. Open the **Applications** folder. Hold down **Control** and click **Zenit PDF** (or
   right-click it), then choose **Open**.
2. macOS asks whether you are sure you want to open it. Click **Open**.

If there is no **Open** button, click **Cancel** (or **OK**), choose **Apple menu > System
Settings > Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to
*"Zenit PDF" was blocked from use because it is not from an identified developer.* Then click
**Open**. That button, too, appears only for about an hour after you tried to open the app.

## Updating

Zenit PDF never checks for updates by itself. To update:

- **Run the one-line installer again.** It replaces the copy in Applications, or the one in your
  own ~/Applications when the main Applications folder has none, and asks before quitting Zenit
  PDF if it is open. If you installed into another folder with `--dest`, add the same `--dest`
  again (after `bash -s --`). No security question appears afterwards.
- **Or download the new disk image**, quit Zenit PDF, and drag the new **Zenit PDF** onto
  **Applications**. When Finder says an item with that name already exists, click **Replace**.
  macOS may ask the first-launch question again for the new copy.

Your projects are files you saved, and the app's settings and tool presets are kept. A newer
version may save projects that an older version cannot open, so keep a backup of important
projects before you update. Older versions stay available on the
[releases page](https://github.com/ZGColombia/ZenitPDF/releases), and `--version` installs one.

## Uninstalling

Paste this into Terminal:

```sh
curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/uninstall.sh | bash
```

It lists everything it will remove (the app and Zenit PDF's own settings, tool presets and
caches) and deletes nothing until you type **DELETE**. It never touches your projects, PDF
drawings or exports. Quit Zenit PDF first; the uninstaller stops while the app is open. If you
installed into another folder with `--dest`, add `-s -- --app "/that/folder/Zenit PDF.app"`
after `bash`, as the installer told you.

To remove only the app, drag **Zenit PDF** from Applications to the Trash. Its settings then
stay in your Library folder until you run the uninstaller.

## Checking a download yourself

The one-line installer does this for you. For the disk image or zip, download
**SHA256SUMS.txt** from the same release into the same folder, then in Terminal:

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Each file you downloaded must say **OK**. With the [GitHub CLI](https://cli.github.com/) you can
also confirm that a file was built by this project's release workflow:

```sh
gh attestation verify ZenitPDF-1.0.0-universal.dmg --repo ZGColombia/ZenitPDF
```

## Troubleshooting

### "Zenit PDF" is damaged and can't be opened. You should move it to the Trash.

The app is almost certainly not damaged. macOS can show this for an app that is not notarized
and still carries the "downloaded from the internet" flag, and also for a download that did not
finish. Do not move it to the Trash. Either run the one-line installer, which checks the download
and clears the flag, or clear the flag yourself on a copy you downloaded from the releases page:

```sh
xattr -dr com.apple.quarantine "/Applications/Zenit PDF.app"
```

(Change the path if the app is somewhere else.) Then open Zenit PDF normally. If it still will not open, download it again; the download was
probably incomplete.

### "Zenit PDF" can't be opened because Apple cannot check it for malicious software, or because the developer cannot be verified

macOS may word this message either way. Both are macOS's first-launch question, not an error.
Follow [Opening Zenit PDF the first time](#opening-zenit-pdf-the-first-time) for your macOS version.
You can also run the one-line installer, or the `xattr` line above, and open the app normally.

### There is no Open Anyway button in System Settings

It appears only for about an hour after a blocked attempt, and only in **Privacy & Security >
Security**. Double-click Zenit PDF again, then go back to System Settings. Confirming can need an
administrator's name and password; on an account without one, use the one-line installer
instead, which needs no password.

### Zenit PDF does not have permission to read a drawing

Zenit PDF only reads files you give it, a macOS protection called the App Sandbox. When it says
*Zenit PDF does not have permission to read "…"*, click **Grant Access…** and select the drawing
in the window that opens. Opening a drawing with **File > Open** or by dragging it onto Zenit PDF
gives the same permission. This also applies to drawings on a USB drive or a network folder.

### macOS says Zenit PDF "differs from previously opened versions"

macOS asks this once when an updated app's signature is not the one the previous copy had.
Zenit PDF releases are built to keep the same identity, so this should be rare. Choose to open it; your
settings and projects are kept.

### The installer stopped with a message

| Message | What to do |
| --- | --- |
| Could not find GitHub on the internet | Check that the Mac is online (open any website), then run it again. |
| The connection to GitHub failed or timed out | Try again in a few minutes, or on another network. |
| A secure connection to GitHub could not be confirmed | Check the Mac's date and time; a company network filter may be in the way. |
| No published release of Zenit PDF was found | The releases page has nothing to download yet. |
| There is not enough free disk space | Empty the Trash or delete files, then run it again. |
| does not match its published checksum | Run it again. If it repeats, do not install that file; report it on the project's Issues page. |
| Zenit PDF is still open | Quit Zenit PDF (Zenit PDF menu > Quit Zenit PDF), then run it again. |
| Please run the installer as yourself, without sudo | Run the line exactly as shown, without `sudo`. |

A stop before the final step leaves an installed copy exactly as it was.

### Where did it go?

In **Applications**, or, if the installer offered to install just for you, in the Applications
folder inside your home folder (Finder > **Go > Home**, then **Applications**). Spotlight finds
it either way: press **Command-Space** and type *Zenit PDF*.
