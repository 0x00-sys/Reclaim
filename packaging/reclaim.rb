# Cask for the personal tap. Lives at Casks/reclaim.rb in the homebrew-tap repo;
# the release workflow prints the sha256 to fill in for each release.
cask "reclaim" do
  version "0.2.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/0x00-sys/Reclaim/releases/download/v#{version}/Reclaim-#{version}.dmg"
  name "Reclaim"
  desc "Find and safely clean the disk space eaten by git worktrees, caches, and AI coding agents"
  homepage "https://github.com/0x00-sys/Reclaim"

  depends_on macos: ">= :tahoe"

  app "Reclaim.app"

  zap trash: [
    "~/Library/Application Support/Reclaim",
    "~/Library/Preferences/dev.reclaim.Reclaim.plist",
  ]
end
