APP_NAME = VoiceInputIME
INSTALL_DIR = /Library/Input\ Methods

.PHONY: generate build install clean restart

generate:
	@export PATH="/opt/homebrew/bin:$$PATH" && xcodegen generate

build: generate
	xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		CONFIGURATION_BUILD_DIR="$(INSTALL_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		build

install: build
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Add in System Settings > Keyboard > Input Sources if first time."

restart:
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@echo "System will auto-restart the input method."

clean:
	@rm -rf $(APP_NAME).xcodeproj
	@rm -rf build/
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean 2>/dev/null || true
