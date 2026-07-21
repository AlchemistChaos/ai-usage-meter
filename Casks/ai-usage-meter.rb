cask "ai-usage-meter" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/AlchemistChaos/ai-usage-meter/releases/download/v#{version}/AIUsageMeter-#{version}.dmg"
  name "AI Usage Meter"
  desc "Local Claude and Codex subscription usage dashboard for macOS"
  homepage "https://github.com/AlchemistChaos/ai-usage-meter"

  depends_on macos: :sonoma

  app "CCManager.app"

  zap trash: [
    "~/.ccmanager",
    "~/Library/Preferences/com.saphaare.ccmanager.plist",
  ]
end
