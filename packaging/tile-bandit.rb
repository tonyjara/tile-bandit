# The Homebrew cask, kept here so it's versioned with the app it describes.
# Copy it to Casks/tile-bandit.rb in the tap repo (tonyjara/homebrew-tap) on
# each release; `make notarized` prints the version and sha256 to paste in.
cask "tile-bandit" do
  version "0.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_MAKE_NOTARIZED"

  url "https://github.com/tonyjara/tile-bandit/releases/download/v#{version}/TileBandit-#{version}.zip"
  name "Tile Bandit"
  desc "Keyboard-driven workspace switcher for the menu bar"
  homepage "https://github.com/tonyjara/tile-bandit"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "Tile Bandit.app"

  # The config lives outside the bundle, so uninstall leaves it behind unless
  # it's named here. `brew uninstall --zap` is what removes it.
  zap trash: [
    "~/.config/tilebandit",
  ]
end
