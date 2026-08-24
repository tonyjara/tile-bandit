APP_NAME = Tile Bandit
BUILD_DIR = .build/release
APP_DIR = dist/$(APP_NAME).app
# Ad-hoc by default. The Accessibility (TCC) grant is tied to the signature,
# so ad-hoc re-signing resets it on every rebuild — pass a stable identity
# (make app CODESIGN_ID="Apple Development: you@example.com (TEAMID)") to keep it.
CODESIGN_ID ?= -

.PHONY: run dev build release app clean

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
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp "$(BUILD_DIR)/TileBandit" "$(APP_DIR)/Contents/MacOS/TileBandit"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	codesign --force --sign "$(CODESIGN_ID)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) — run with: open \"$(APP_DIR)\""

clean:
	rm -rf .build dist
