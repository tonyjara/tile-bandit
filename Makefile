APP_NAME = Tile Bandit
BUILD_DIR = .build/release
APP_DIR = dist/$(APP_NAME).app
# Ad-hoc by default. The Accessibility (TCC) grant is tied to the signature,
# so ad-hoc re-signing resets it on every rebuild — pass a stable identity
# (make app CODESIGN_ID="Apple Development: you@example.com (TEAMID)") to keep it.
CODESIGN_ID ?= -
# Extra codesign flags. `notarized` sets the two Apple insists on; an ordinary
# `make app` stays plain, since a development build has nothing to gain here.
CODESIGN_FLAGS ?=
# The notarytool keychain profile, created once and interactively so no
# password ever goes near this file:
#   xcrun notarytool store-credentials tile-bandit \
#       --apple-id you@example.com --team-id TEAMID
NOTARY_PROFILE ?= tile-bandit
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP = dist/TileBandit-$(VERSION).zip
ICONSET = .build/AppIcon.iconset
GLYPH_SHEET = .build/glyphs.png

.PHONY: run dev build release app notarized check-identity icon glyphs clean

run:
	swift run

# Auto-rebuild & relaunch on source changes (needs: brew install watchexec)
dev:
	watchexec --restart --exts swift -- swift run

build:
	swift build

release:
	swift build -c release

# Wraps the release binary in a real .app bundle (menu bar only, no Dock icon).
app: release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/TileBandit" "$(APP_DIR)/Contents/MacOS/TileBandit"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) — run with: open \"$(APP_DIR)\""

# A signed, notarised, stapled zip — what the Homebrew cask downloads.
#
#   make notarized CODESIGN_ID="Developer ID Application: Name (TEAMID)"
#
# Hardened runtime and a secure timestamp are both required for notarisation,
# and neither can be added afterwards. No entitlements file: Accessibility and
# the event tap are TCC grants rather than entitlements, and shelling out to
# hidutil is allowed under the hardened runtime as it stands.
notarized: CODESIGN_FLAGS = --options runtime --timestamp
# The identity is checked first, as its own prerequisite: finding out the
# certificate is wrong *after* a release build is a slow way to learn it.
notarized: check-identity app
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_DIR)"
# Re-zipped after stapling: the archive we submitted predates the ticket, and
# shipping that one is the classic way to hand users an unnotarised-looking app.
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP)"
	@echo
	@spctl --assess --type execute --verbose=2 "$(APP_DIR)"
	@echo "$(ZIP)"
	@shasum -a 256 "$(ZIP)" | awk '{print "  sha256 \"" $$1 "\""}'

check-identity:
	@case "$(CODESIGN_ID)" in \
	  "Developer ID Application:"*) ;; \
	  *) echo "CODESIGN_ID must be a Developer ID Application identity."; \
	     echo "Ad-hoc and Apple Development certificates cannot be notarised."; \
	     echo "Available:"; security find-identity -v -p codesigning | sed 's/^/  /'; \
	     exit 1 ;; \
	esac

# Re-bakes Resources/AppIcon.icns from AppIconArt (BanditIcons.swift). Checked
# in, so `make app` stays a copy — run this only when the artwork changes.
icon:
	@mkdir -p .build
	swiftc -O Sources/TileBandit/BanditIcons.swift Tools/AppIconGen.swift -o .build/appicongen
	.build/appicongen "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o Resources/AppIcon.icns
	@echo "Wrote Resources/AppIcon.icns"

# Contact sheet of the drawn menu bar glyphs, light and dark, 16pt upwards.
# A 16pt drawing can't be judged from source.
glyphs:
	@mkdir -p .build
	swiftc -O Sources/TileBandit/BanditIcons.swift Tools/GlyphSheet.swift -o .build/glyphsheet
	@open "$$(.build/glyphsheet $(GLYPH_SHEET))"

clean:
	rm -rf .build dist
