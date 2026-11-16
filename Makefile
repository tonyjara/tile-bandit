APP_NAME = Tile Bandit
BUILD_DIR = .build/release
APP_DIR = dist/$(APP_NAME).app
# The privileged helper behind Stay Awake with Lid Closed, and the launchd
# plist SMAppService registers it from. Both go inside the bundle.
HELPER = TileBanditSleepGuard
HELPER_ID = com.twonary.TileBandit.SleepGuard
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

# How far back `make log` reads: 30m, 3h, 2d.
SINCE ?= 1h
LOG_PREDICATE = subsystem == "com.twonary.TileBandit"

.PHONY: run dev build test log log-live release app signed notarized check-identity icon glyphs clean

run:
	swift run

# Auto-rebuild & relaunch on source changes (needs: brew install watchexec)
dev:
	watchexec --restart --exts swift -- swift run

build:
	swift build

test:
	swift test

# What the switcher did and why (Log.swift). /usr/bin/log by its path: zsh has
# a builtin called log.
log:
	@/usr/bin/log show --last $(SINCE) --info --style compact --predicate '$(LOG_PREDICATE)'

log-live:
	@/usr/bin/log stream --info --style compact --predicate '$(LOG_PREDICATE)'

release:
	swift build -c release

# Wraps the release binary in a real .app bundle (menu bar only, no Dock icon).
app: release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources" "$(APP_DIR)/Contents/Library/LaunchDaemons"
	cp "$(BUILD_DIR)/TileBandit" "$(APP_DIR)/Contents/MacOS/TileBandit"
	cp "$(BUILD_DIR)/$(HELPER)" "$(APP_DIR)/Contents/MacOS/$(HELPER)"
	cp "Resources/$(HELPER_ID).plist" "$(APP_DIR)/Contents/Library/LaunchDaemons/$(HELPER_ID).plist"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/AppIcon.icns"
# The helper first, under its own identifier: codesign seals code that is
# already signed inside a bundle, it doesn't sign it for you. Ad-hoc signed
# (the default) the helper has no team, so it lets nobody in and the menu
# item says why — Stay Awake with Lid Closed needs `make signed` or better.
	codesign --force $(CODESIGN_FLAGS) --identifier "$(HELPER_ID)" --sign "$(CODESIGN_ID)" "$(APP_DIR)/Contents/MacOS/$(HELPER)"
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_ID)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) — run with: open \"$(APP_DIR)\""

# A local build signed the way a release is, minus the notarisation — enough
# for macOS to register the helper, and for the helper to recognise the app.
#
#   make signed CODESIGN_ID="Developer ID Application: Name (TEAMID)"
#
# Run it from where it will live (/Applications): the helper is registered by
# the bundle's path.
signed: CODESIGN_FLAGS = --options runtime --timestamp
signed: app
	@codesign --verify --strict --deep --verbose=1 "$(APP_DIR)"

# A signed, notarised, stapled zip — what the Homebrew cask downloads.
#
#   make notarized CODESIGN_ID="Developer ID Application: Name (TEAMID)"
#
# Hardened runtime and a secure timestamp are both required for notarisation,
# and neither can be added afterwards. No entitlements file: Accessibility and
# the event tap are TCC grants rather than entitlements, shelling out to
# hidutil is allowed under the hardened runtime as it stands, and the helper
# gets its privilege from launchd running it as root, not from an entitlement.
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
