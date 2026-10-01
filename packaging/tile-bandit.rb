# The Homebrew cask, kept here so it's versioned with the app it describes.
# Copy it to Casks/tile-bandit.rb in the tap repo (tonyjara/homebrew-tap) on
# each release; `make notarized` prints the version and sha256 to paste in.
cask "tile-bandit" do
  version "1.4.0"
  sha256 "48c020d102353791583dd58c01b218fc39edf23f1e75df369a472fb391b3e140"

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
