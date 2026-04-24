APP_NAME = VoiceInput
BUILD_DIR = build
INSTALL_DIR = /Applications

.PHONY: generate build sign install run clean

# Default target: build fresh, then install + launch. Always replaces any
# previously installed VoiceInput.app so the user never runs a stale build.
run: build install

generate:
	@export PATH="/opt/homebrew/bin:$$PATH" && xcodegen generate

# xcodebuild may fail at the CodeSign step if iCloud/File Provider re-adds
# extended attributes to build/ while codesign runs. We let it fail and then
# clean+sign manually.
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

# Kill any running instance, wipe the installed app, copy fresh build,
# launch. Always replaces — never leaves a stale version behind.
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

clean:
	@rm -rf $(BUILD_DIR)/
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean 2>/dev/null || true
