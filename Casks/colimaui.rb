cask "colimaui" do
  version "0.1.0"
  sha256 "d5f1a9c68a0285fc923a9cbafe945f8c02860aa423a7745cb3b34f6c9956138c"

  url "https://github.com/pawiromitchel/colimaui/releases/download/v#{version}/ColimaUI-#{version}.zip"
  name "ColimaUI"
  desc "Native macOS interface for Colima"
  homepage "https://github.com/pawiromitchel/colimaui"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  # Homebrew installs these first if they're missing, so a fresh Mac gets everything in one command.
  depends_on formula: ["colima", "docker"]

  app "ColimaUI.app"

  # ColimaUI is ad-hoc signed rather than notarized, so Gatekeeper would refuse a quarantined copy.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ColimaUI.app"],
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/com.pawiromitchel.ColimaUI.plist",
    "~/Library/Saved Application State/com.pawiromitchel.ColimaUI.savedState",
  ]
end
