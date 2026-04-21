# VoiceInput iOS build helpers.
#
# Requires: Xcode 16+, xcodegen (brew install xcodegen).
# Signing: open VoiceInputiOS.xcodeproj after `make gen`, set your Team on both targets,
# then Product → Archive for TestFlight upload.

PROJECT = VoiceInputiOS.xcodeproj
SCHEME_APP = VoiceInputiOS
SCHEME_KB  = VoiceInputKeyboard

.PHONY: gen open build-sim clean

gen:
	xcodegen generate

open: gen
	open $(PROJECT)

build-sim: gen
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME_APP) \
	  -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' \
	  CODE_SIGNING_ALLOWED=NO \
	  build

clean:
	rm -rf $(PROJECT) build DerivedData
