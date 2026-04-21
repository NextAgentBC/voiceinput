# VoiceInput iOS

iOS port of VoiceInput. Ships as:

- **Container app** (`VoiceInputiOS`) — onboarding, permissions, Settings.
- **Custom Keyboard Extension** (`VoiceInputKeyboard`) — mic button; press-and-hold to record, release to insert transcription into whatever text field is focused in any app.

Press-and-hold the 🌐 globe key on iOS to switch to the VoiceInput keyboard.

## Architecture

```
ios/
  App/              SwiftUI container app
  Keyboard/         UIInputViewController + SwiftUI mic UI
  Shared/           App-Group-backed settings (SharedSettings)
  Entitlements/     com.apple.security.application-groups
  project.yml       xcodegen spec
```

Speech recognition uses `SFSpeechRecognizer` with `SFSpeechAudioBufferRecognitionRequest`, preferring on-device mode. Cloud STT is not wired into the extension yet — add it by porting `Sources/VoiceInputIME/Core/CloudSTTEngine.swift` once the basic flow is verified.

## Setup

```bash
brew install xcodegen
cd ios
make open            # generates and opens Xcode
```

In Xcode:

1. Select both targets → **Signing & Capabilities** → pick your team.
2. Create an App Group `group.com.voiceinput.shared` in the Apple Developer portal and add it to both targets (already referenced in the entitlements files).
3. Build & Run the `VoiceInputiOS` scheme on a real device (the simulator cannot grant keyboard Full Access in a realistic way).

## Trying on iPhone (TestFlight)

1. Apple Developer Program membership ($99/yr).
2. `Product → Archive` in Xcode with the `VoiceInputiOS` scheme.
3. Organizer → **Distribute App → App Store Connect → Upload**.
4. On App Store Connect, enable the build for **TestFlight** and create a **public link**.
5. Testers install the TestFlight app, tap the link, and receive the build. Re-archive within 90 days to refresh.

Alternative: **Ad-hoc** (collect tester UDIDs, limit 100) or **free sideloading** via AltStore / Sideloadly (7-day expiry, fragile).

## First-run on the test device

1. Open **VoiceInput** app → grant Microphone + Speech permission.
2. Open **Settings → General → Keyboards → Keyboards → Add New Keyboard → VoiceInput**.
3. Tap the newly-added **VoiceInput** row → enable **Allow Full Access**.
4. In any app, long-press 🌐 → pick **VoiceInput** → hold the big mic button and speak.

## Known gaps vs. macOS version

- Cloud STT and LLM refinement not wired into the keyboard yet.
- Vocabulary DB / contextual strings not ported (keyboard extension memory budget is ~60MB).
- No undo button; rely on shake-to-undo from the host app.

## ⚠ Architectural blocker — mic access in keyboard extension is impossible

Status as of 2026-04-20, iOS 17/18: a custom keyboard extension **cannot** call `AVAudioRecorder.record()` or `AVAudioEngine.start()` in its own process. `CMSUtility_IsAllowedToStartRecording` denies it at the entitlement level with `AVAudioRecorder.record()` returning `false` or CoreAudio OSStatus `'what'` (2003329396). Full Access does not unlock the microphone; `RequestsOpenAccess` only grants network + shared containers + keychain. Apple has enforced this since iOS 8.

### What works on the current branch

- Container app (target `VoiceInputiOS`) — onboarding, permissions, Settings. Builds, installs, runs.
- Keyboard extension (target `VoiceInputKeyboard`) — WeChat-style "Hold to Talk" bar UI. Builds, installs, renders correctly on simulator. On real device the bar shows an error like `VoiceInput#3: record()=false mic=granted cat=PlayAndRecord` the moment the user presses.

### The iFlytek / Gboard / SwiftKey pattern (not yet implemented here)

Production iOS keyboards with voice input work around the mic ban like this:

1. Keyboard extension button → `open(url)` via responder-chain walk (`UIInputViewController` doesn't expose `extensionContext.open` to URL schemes).
2. iOS briefly switches to the container app (200–400 ms flash).
3. Container app starts `AVAudioEngine` + `SFSpeechRecognizer` under a background-audio entitlement and keeps recording after iOS swaps the host app back.
4. Audio/transcript flows back to the keyboard via **App Group** (shared `UserDefaults` / shared file / Darwin notification).
5. Keyboard inserts text via `textDocumentProxy.insertText(_:)`.

Users see the red iOS recording pill at the top of the screen (the container app is still recording in the background). iFlytek documents this as "免跳转" — it is still a hop, just scripted to feel instant.

### To continue this port, you need

- A registered App Group identifier (original `group.com.voiceinput.shared` is owned by another team — pick a team-scoped name like `group.ca.nextagent.voiceinput`).
- URL scheme + `LSApplicationQueriesSchemes` entry on the container app.
- Background audio capability on the container app.
- Rewrite `KeyboardRecorder.swift` to open-URL instead of recording in-process.
- Container app UI that auto-dismisses after one shot of dictation.

Roughly 2–3 hours of work plus another TestFlight cycle. See the Whisper/KeyboardKit findings compiled during the investigation for why no open-source project has bypassed this — nobody has.

### Build history in this branch

- builds 1–3: signing, bundle ID, icon, orientation fixes to get TestFlight accepting the binary.
- build 4: UIKit `UILongPressGestureRecognizer` to fix SwiftUI gesture-on-Shape issue.
- build 5: minimal `.record/.measurement` audio session (still failed on device).
- build 6: switched to `AVAudioRecorder` + `SFSpeechURLRecognitionRequest` (still failed on device).
- build 7: WeChat-style bar UI, removed custom globe (iOS system bar already has one).
- build 8: added detailed error reporting — `mic=granted cat=PlayAndRecord`.
- build 9: full `.playAndRecord + mixWithOthers + allowBluetooth` session — still blocked by CMSUtility.

All nine builds reproduced the same block on-device.
