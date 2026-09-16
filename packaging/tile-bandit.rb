# The Homebrew cask, kept here so it's versioned with the app it describes.
# Copy it to Casks/tile-bandit.rb in the tap repo (tonyjara/homebrew-tap) on
# each release; `make notarized` prints the version and sha256 to paste in.
cask "tile-bandit" do
  version "1.0.0"
  sha256 "72de1b0735a8d394d2e85de07131b149479990046aacb3438393a4dfabc0cb3d"

  url "https://github.com/tonyjara/tile-bandit/releases/download/v#{version}/TileBandit-#{version}.zip"
  name "Tile Bandit"
  desc "Keyboard-driven workspace switcher for the menu bar"
  homepage "https://github.com/tonyjara/tile-bandit"

  livecheck do
    url :url
    strategy :github_latest
  end

  # A bare symbol is a *minimum*: the cask DSL parses it with comparator ">=".
  # The ">= :ventura" string form means the same thing and is deprecated.
  depends_on macos: :ventura

  app "Tile Bandit.app"

  # The config lives outside the bundle, so uninstall leaves it behind unless
  # it's named here. `brew uninstall --zap` is what removes it.
  zap trash: [
    "~/.config/tilebandit",
  ]
end
