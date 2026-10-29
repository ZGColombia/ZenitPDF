# Homebrew cask for Zenit PDF: a TEMPLATE for the maintainer's own tap.
#
# Not published anywhere yet. No tap exists, so `brew install` cannot find this cask until the
# maintainer creates one; see Packaging/homebrew/README.md. Scripts/update-cask.sh VERSION
# fills in `version` and `sha256` from the release's SHA256SUMS.txt.
cask "zenit-pdf" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ZGColombia/ZenitPDF/releases/download/v#{version}/ZenitPDF-#{version}-universal.dmg"
  name "Zenit PDF"
  desc "Construction takeoff and PDF markup"
  homepage "https://github.com/ZGColombia/ZenitPDF"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Zenit PDF.app"

  # Zenit PDF is ad-hoc signed and not notarized (there is no Apple Developer ID), so a
  # quarantined copy is stopped by Gatekeeper. Homebrew has already checked the download
  # against the sha256 above, the same check Scripts/install.sh makes before it clears the flag
  # on the one app it installed; this does the same, and nothing else.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Zenit PDF.app"]
  end

  uninstall quit: "com.zenitgroup.zenitpdf"

  # Zenit PDF's own data only, the same list as Scripts/uninstall.sh. Projects, drawings and
  # exports live wherever the person saved them and are never listed here.
  zap trash: [
    "~/Library/Application Support/com.zenitgroup.zenitpdf",
    "~/Library/Application Support/Zenit PDF",
    "~/Library/Caches/com.zenitgroup.zenitpdf",
    "~/Library/Containers/com.zenitgroup.zenitpdf",
    "~/Library/Containers/com.zenitgroup.zenitpdf.*",
    "~/Library/Group Containers/group.com.zenitgroup.zenitpdf",
    "~/Library/HTTPStorages/com.zenitgroup.zenitpdf",
    "~/Library/HTTPStorages/com.zenitgroup.zenitpdf.binarycookies",
    "~/Library/Logs/com.zenitgroup.zenitpdf",
    "~/Library/Logs/Zenit PDF",
    "~/Library/Preferences/ByHost/com.zenitgroup.zenitpdf.*.plist",
    "~/Library/Preferences/com.zenitgroup.zenitpdf.plist",
    "~/Library/Saved Application State/com.zenitgroup.zenitpdf.savedState",
    "~/Library/WebKit/com.zenitgroup.zenitpdf",
  ]
end
