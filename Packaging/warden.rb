cask "warden" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/fus3r/warden/releases/download/v#{version}/Warden-#{version}.zip"
  name "Warden"
  desc "Menu bar monitor for Claude Code and Codex sessions, prompts, and usage limits"
  homepage "https://github.com/fus3r/warden"

  depends_on macos: ">= :sonoma"

  app "Warden.app"

  uninstall quit: "com.fus3r.Warden"

  zap trash: [
    "~/Library/Application Support/Warden",
    "~/Library/Preferences/com.fus3r.Warden.plist",
  ]
end
