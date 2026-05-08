# VoiceInput iOS build helpers.
#
# Requires: Xcode 16+, xcodegen (brew install xcodegen).
# Signing: open VoiceInputiOS.xcodeproj after `make open`, set your Team on both targets,
# then Product → Archive for TestFlight upload.

PROJECT    = VoiceInputiOS.xcodeproj
SCHEME_APP = VoiceInputiOS
SCHEME_KB  = VoiceInputKeyboard

.PHONY: generate gen build open archive build-sim clean

# Canonical name expected by the plan + CI.
generate:
	@xcodegen generate

# Short alias kept for backward compat.
gen: generate

build: generate
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-configuration Debug \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO \
		build

open: generate
	@open $(PROJECT)

archive: generate
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-configuration Release \
		-archivePath build/VoiceInputiOS.xcarchive \
		archive

# Alias kept for backward compat.
build-sim: build

clean:
	@rm -rf build/ DerivedData/ $(PROJECT)
