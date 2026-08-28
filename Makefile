# Protokoll - local build & install for developers and testers.
#
# These targets wrap the canonical XcodeGen + xcodebuild flow so you can build
# a Release Protokoll.app, drop it in /Applications, or zip it for a tester.
# This is for LOCAL dev / tester handoff only. The signed, notarized channel is
# the Homebrew cask + release workflow (see README "Releases"), not this file.

APP_NAME    := Protokoll
SCHEME      := Protokoll-Mac
PROJECT     := Protokoll.xcodeproj
CONFIG      := Release
DERIVED     := build/dd
INSTALL_DIR := /Applications

PRODUCTS := $(DERIVED)/Build/Products/$(CONFIG)
APP      := $(PRODUCTS)/$(APP_NAME).app
ZIP      := $(APP_NAME).zip

.DEFAULT_GOAL := help

.PHONY: help generate build install dist run clean

help: ## List the available targets
	@echo "Protokoll local build & install"
	@echo
	@echo "  make generate  - regenerate $(PROJECT) with xcodegen"
	@echo "  make build     - build a Release $(APP_NAME).app into $(DERIVED)"
	@echo "  make install   - copy the built app into $(INSTALL_DIR)"
	@echo "  make dist      - zip the app as $(ZIP) for handing to a tester"
	@echo "  make run       - install, then open the app"
	@echo "  make clean     - remove $(DERIVED), $(ZIP), and $(PROJECT)"

generate: ## Regenerate the gitignored Xcode project
	xcodegen generate

build: generate ## Build a Release app (unsigned, ad-hoc signed) into build/dd
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration $(CONFIG) -destination 'platform=macOS' \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build
	@codesign --force --deep --sign - "$(APP)"
	@echo "Built: $(APP)"

install: build ## Remove any installed copy and install the fresh build
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app" || \
	  { echo "Could not remove $(INSTALL_DIR)/$(APP_NAME).app - re-run with sudo?"; exit 1; }
	@ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app" || \
	  { echo "Copy to $(INSTALL_DIR) failed - re-run with sudo?"; exit 1; }
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"

dist: build ## Zip the app for a tester (not notarized)
	@rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@echo "Wrote: $(ZIP)"
	@echo "Not notarized: a tester may need 'xattr -dr com.apple.quarantine $(APP_NAME).app' or right-click > Open."

run: install ## Install, then launch the app
	open "$(INSTALL_DIR)/$(APP_NAME).app"

clean: ## Remove build output, the zip, and the generated project
	rm -rf "$(DERIVED)" "$(ZIP)" "$(PROJECT)"
