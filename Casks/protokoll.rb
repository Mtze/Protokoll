cask "protokoll" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Mtze/Protokoll/releases/download/v#{version}/Protokoll.zip"
  name "Protokoll"
  desc "Local, private meeting recorder and protocol pipeline"
  homepage "https://github.com/Mtze/Protokoll"

  depends_on macos: :sonoma # macOS 14+ (project.yml deploymentTarget). Bare symbol means ">=".

  app "Protokoll.app"

  zap trash: [
    "~/Library/Application Support/Protokoll",
    "~/Library/Preferences/com.protokoll.mac.plist",
  ]

  # Until Developer ID notarization is enabled, the release build is unsigned. On
  # macOS 15 (Sequoia) the old right-click > Open bypass is gone, so point users at
  # System Settings or xattr. Remove this caveat once the notarized pipeline is live.
  caveats <<~EOS
    Protokoll is not yet notarized. If macOS blocks it on first launch, either
    approve it under System Settings > Privacy & Security ("Open Anyway"), or run:
      xattr -dr com.apple.quarantine "/Applications/Protokoll.app"
    Tip: install with `brew install --cask --no-quarantine protokoll` to skip this.
  EOS
end
