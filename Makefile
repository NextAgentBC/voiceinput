APP_NAME = VoiceInput
BUILD_DIR = build

.PHONY: generate build clean

generate:
	@export PATH="/opt/homebrew/bin:$$PATH" && xcodegen generate

build: generate
	xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		CONFIGURATION_BUILD_DIR="$(BUILD_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		build

clean:
	@rm -rf $(BUILD_DIR)/
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean 2>/dev/null || true
