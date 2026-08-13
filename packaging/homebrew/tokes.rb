# Homebrew cask for Tokes. Lives at Casks/tokes.rb in the tap repo
# (github.com/appideasDOTcom/homebrew-tap). After each release, bump
# `version` and `sha256` (printed in the GitHub release notes).
cask "tokes" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/appideasDOTcom/tokes-app/releases/download/v#{version}/Tokes-#{version}.zip"
  name "Tokes"
  desc "Menu bar monitor for Claude and GitHub Copilot usage limits"
  homepage "https://github.com/appideasDOTcom/tokes-app"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Tokes.app"

  zap trash: [
    "~/Library/Application Support/Tokes",
    "~/Library/Preferences/com.appideas.tokes.plist",
  ]

  caveats <<~EOS
    Tokes is not yet notarized. On first launch, right-click Tokes.app and
    choose Open, or install with:
      brew install --cask --no-quarantine appideasDOTcom/tap/tokes
  EOS
end
