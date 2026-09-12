cask "ai-usage-meter" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/AlchemistChaos/ai-usage-meter/releases/download/v#{version}/AIMeter-#{version}.dmg"
  name "AI Meter"
  desc "Local Claude and Codex subscription usage dashboard"
  homepage "https://github.com/AlchemistChaos/ai-usage-meter"

  depends_on macos: :sonoma

  app "AI Meter.app"

  uninstall quit:  "com.alchemistchaos.aimeter",
            trash: "~/Library/Application Support/AI Meter"

  zap trash: [
    "~/.ccmanager",
    "~/Library/Application Support/AI Meter",
    "~/Library/Preferences/com.alchemistchaos.aimeter.plist",
    "~/Library/Preferences/com.saphaare.ccmanager.plist",
  ]
end
