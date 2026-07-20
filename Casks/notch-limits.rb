cask "notch-limits" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/everyai-com/notch-limits/releases/download/v#{version}/NotchLimits-#{version}.dmg"
  name "Notch Limits"
  desc "Claude Code and Codex usage limits in your Mac's notch"
  homepage "https://github.com/everyai-com/notch-limits"

  depends_on macos: ">= :sonoma"

  app "CCManager.app"

  zap trash: [
    "~/.ccmanager",
    "~/Library/Preferences/com.saphaare.ccmanager.plist",
  ]
end
