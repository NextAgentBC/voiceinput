APP_NAME = VoiceInput
BUILD_DIR = build
INSTALL_DIR = /Applications

# Version — also update Resources/Info.plist (CFBundleShortVersionString).
VERSION = 0.3.0

# Developer ID for distribution builds. Leave empty to fall back to ad-hoc.
DEV_ID ?= Developer ID Application: MMC Wellness Group Inc. (WA4JUD762R)

# Keychain profile for notarytool (create once with:
#   xcrun notarytool store-credentials voiceinput-notary --apple-id ... --team-id WA4JUD762R --password ...).
NOTARY_PROFILE ?= voiceinput-notary

.PHONY: generate build sign install run clean dist dist-sign notarize dmg release

# Default target: dev build → install → launch. Ad-hoc signed, arm64 native.
# For a shippable DMG use `make release`.
run: build install

generate:
	@export PATH="/opt/homebrew/bin:$$PATH" && xcodegen generate

# Dev build: native arch, ad-hoc sign. Fast.
build: generate
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		CONFIGURATION_BUILD_DIR="$(BUILD_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		build; \
	STATUS=$$?; \
	if [ ! -f "$(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" ]; then \
		exit $$STATUS; \
	fi; \
	$(MAKE) sign

sign:
	@for i in 1 2 3 4 5; do \
		xattr -cr "$(BUILD_DIR)/$(APP_NAME).app" 2>/dev/null || true; \
		find "$(BUILD_DIR)/$(APP_NAME).app" -exec xattr -c {} \; 2>/dev/null || true; \
		if codesign --force --sign - --entitlements Entitlements.plist --timestamp=none "$(BUILD_DIR)/$(APP_NAME).app" 2>/dev/null; then \
			echo "Signed $(BUILD_DIR)/$(APP_NAME).app (attempt $$i)"; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "Codesign failed after 5 retries"; exit 1

install:
	@echo "Stopping any running $(APP_NAME)..."
	@pkill -9 -f "$(INSTALL_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@pkill -9 -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@echo "Removing old $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installing fresh build..."
	@cp -R "$(BUILD_DIR)/$(APP_NAME).app" "$(INSTALL_DIR)/$(APP_NAME).app"
	@xattr -cr "$(INSTALL_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@echo "Removing build copy to avoid confusion..."
	@rm -rf "$(BUILD_DIR)/$(APP_NAME).app"
	@echo "Launching $(INSTALL_DIR)/$(APP_NAME).app..."
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

# --- Distribution pipeline ---------------------------------------------------
# dist       : universal (x86_64 + arm64) build, hardened-runtime, Developer ID signed
# notarize   : submit to Apple notary + staple ticket
# dmg        : package signed + stapled .app into VoiceInput-<VER>.dmg
# release    : dist → notarize → dmg

dist: generate
	@rm -rf "$(BUILD_DIR)/$(APP_NAME).app"
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-destination "generic/platform=macOS" \
		CONFIGURATION_BUILD_DIR="$(BUILD_DIR)" \
		ARCHS="x86_64 arm64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build; \
	STATUS=$$?; \
	if [ ! -f "$(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" ]; then \
		exit $$STATUS; \
	fi; \
	$(MAKE) dist-sign

STAGE_DIR = /tmp/voiceinput-stage

dist-sign:
	@echo "Moving build outside iCloud-watched path to prevent xattr re-injection..."
	@rm -rf "$(STAGE_DIR)"
	@mkdir -p "$(STAGE_DIR)"
	@cp -R "$(BUILD_DIR)/$(APP_NAME).app" "$(STAGE_DIR)/"
	@xattr -cr "$(STAGE_DIR)/$(APP_NAME).app"
	@find "$(STAGE_DIR)/$(APP_NAME).app" -exec xattr -c {} \; 2>/dev/null || true
	@echo "Signing with: $(DEV_ID)"
	@codesign --force --deep --options runtime --timestamp \
		--entitlements Entitlements.plist \
		--sign "$(DEV_ID)" \
		"$(STAGE_DIR)/$(APP_NAME).app"
	@codesign --verify --deep --strict --verbose=2 "$(STAGE_DIR)/$(APP_NAME).app"
	@echo "Architectures:"
	@lipo -info "$(STAGE_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	@echo "Signed bundle staged at $(STAGE_DIR)/$(APP_NAME).app"

notarize:
	@test -d "$(STAGE_DIR)/$(APP_NAME).app" || (echo "No $(STAGE_DIR)/$(APP_NAME).app — run 'make dist' first"; exit 1)
	@echo "Zipping for notarization..."
	@ditto -c -k --keepParent "$(STAGE_DIR)/$(APP_NAME).app" "$(STAGE_DIR)/$(APP_NAME)-notarize.zip"
	@echo "Submitting to Apple notary (profile: $(NOTARY_PROFILE))..."
	@xcrun notarytool submit "$(STAGE_DIR)/$(APP_NAME)-notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	@echo "Stapling ticket to .app..."
	@xcrun stapler staple "$(STAGE_DIR)/$(APP_NAME).app"
	@xcrun stapler validate "$(STAGE_DIR)/$(APP_NAME).app"
	@rm -f "$(STAGE_DIR)/$(APP_NAME)-notarize.zip"

dmg:
	@test -d "$(STAGE_DIR)/$(APP_NAME).app" || (echo "No $(STAGE_DIR)/$(APP_NAME).app"; exit 1)
	@rm -f "$(STAGE_DIR)/$(APP_NAME)-$(VERSION).dmg"
	@rm -rf "$(STAGE_DIR)/dmg-staging"
	@mkdir -p "$(STAGE_DIR)/dmg-staging"
	@cp -R "$(STAGE_DIR)/$(APP_NAME).app" "$(STAGE_DIR)/dmg-staging/"
	@ln -sf /Applications "$(STAGE_DIR)/dmg-staging/Applications"
	@hdiutil create -volname "$(APP_NAME) $(VERSION)" \
		-srcfolder "$(STAGE_DIR)/dmg-staging" \
		-ov -format UDZO \
		"$(STAGE_DIR)/$(APP_NAME)-$(VERSION).dmg"
	@rm -rf "$(STAGE_DIR)/dmg-staging"
	@mkdir -p "$(BUILD_DIR)"
	@cp "$(STAGE_DIR)/$(APP_NAME)-$(VERSION).dmg" "$(BUILD_DIR)/"
	@xattr -c "$(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg" 2>/dev/null || true
	@echo "DMG: $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg"

release: dist notarize dmg
	@echo "Release ready: $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg"

clean:
	@rm -rf $(BUILD_DIR)/
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean 2>/dev/null || true
