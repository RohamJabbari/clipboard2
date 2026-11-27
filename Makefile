APP_NAME   := Clipboard2
# This branch builds a separate test flavour that talks to the origin server.
PRODUCT    := clipboard2-origin
BUNDLE_ID  := at.softmaze.Clippy.test
PROJECT    := $(APP_NAME).xcodeproj
SCHEME     := $(APP_NAME)
DERIVED    := build
RELEASE_APP := $(DERIVED)/Build/Products/Release/$(PRODUCT).app
INSTALL_DIR := /Applications

.PHONY: all generate build debug test install run icon pkg release ios-build ios-test windows-test windows-release server-test server-deploy clean

# Sign with Developer ID when that certificate exists, so local installs and the .pkg share one
# signature (Accessibility/Keychain grants are tied to it). Otherwise Apple Development.
DEVID_APP := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application")
ifneq ($(DEVID_APP),0)
SIGN_ARGS := CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=XWTH2647FF CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp
# No system AutoFill in this flavour: its profiles are for the released app's ids, and the
# extension would share the released app's Keychain group.
AUTOFILL_ARGS = $(info   AutoFill: off in the clipboard2-origin flavour)
else
AUTOFILL_ARGS = $(info   AutoFill: skipped (needs a Developer ID Application certificate))
endif

all: build

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet $(SIGN_ARGS) $(AUTOFILL_ARGS)

debug: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' test -quiet

install: build
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@pkill -x $(PRODUCT) >/dev/null 2>&1 || true
	@pkill -x clipboard2-test >/dev/null 2>&1 || true
	rm -rf "$(INSTALL_DIR)/$(PRODUCT).app" "$(INSTALL_DIR)/clipboard2-test.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"
	codesign --verify --strict "$(INSTALL_DIR)/$(PRODUCT).app"
	open "$(INSTALL_DIR)/$(PRODUCT).app"

run: install

pkg:
	scripts/make-pkg.sh

# make release VERSION=1.2.0 — build, notarize, publish on GitHub; installed apps update in place.
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z" && exit 1)
	scripts/release.sh $(VERSION)

# iOS app (docs/features/ios.md): Simulator builds and tests, Apple Development signing (no profile
# needed for the Simulator). `make ios-test IOS_SIM="iPhone 17 Pro"` picks another simulator.
IOS_SCHEME := $(APP_NAME) iOS
IOS_SIM ?= iPhone 17

ios-build: generate
	xcodebuild -project $(PROJECT) -scheme "$(IOS_SCHEME)" -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'generic/platform=iOS Simulator' build -quiet

ios-test: generate
	xcodebuild -project $(PROJECT) -scheme "$(IOS_SCHEME)" -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=iOS Simulator,name=$(IOS_SIM)' test -quiet

# Windows version: tests run locally with .NET 10; the installer is built on GitHub's Windows servers.
windows-test:
	dotnet test windows/tests/Clipboard2.Core.Tests

# make windows-release VERSION=1.1.0 — tags windows-v<version>; GitHub Actions builds the installer,
# publishes the release and the update feed; then the feed is signed here with the offline key in your
# Keychain (scripts/sign-windows-feed.sh). Installed copies only update from a signed feed.
windows-release:
	@test -n "$(VERSION)" || (echo "usage: make windows-release VERSION=x.y.z" && exit 1)
	scripts/sign-windows-feed.sh --check
	git tag "windows-v$(VERSION)"
	git push origin "windows-v$(VERSION)"
	scripts/sign-windows-feed.sh --wait $(VERSION)
	rm -rf windows/src/*/bin windows/src/*/obj windows/tests/*/bin windows/tests/*/obj

# Sync API (server/): integration tests run against an embedded Postgres; deploy goes to Cloud Run.
server-test:
	cd server && npm ci && npx tsc -p tsconfig.json --noEmit && npm test

server-deploy:
	server/deploy.sh

icon:
	swift scripts/make-icon.swift Clipboard2/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf $(DERIVED) $(PROJECT) dist
