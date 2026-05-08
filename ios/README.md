# VoiceInput iOS

iOS port. Ships as:

- **Container app** (`VoiceInputiOS`) — onboarding, permissions, recording, Settings.
- **Custom Keyboard Extension** (`VoiceInputKeyboard`) — mic button; tap to bounce to the container, where recording happens.

## Architecture: bounce-to-container

Apple does not allow keyboard extensions to access the microphone. The standard workaround used by iFlytek, Gboard, SwiftKey, and 搜狗 is to bounce to a container app: the keyboard's mic button opens the container via a custom URL scheme, the container records and runs STT under a `UIBackgroundModes: audio` entitlement, the result is written to a shared App Group, and the keyboard reads it back and pastes via `textDocumentProxy.insertText(_:)`. iOS shows the red recording pill at the top of the screen while the host app is foreground.

```
[Host app] ── tap mic ──> [Keyboard ext] ──open(URL)──> [Container app]
                                                              │
                                                          records
                                                              │
                                                       writes Result
                                                  posts Darwin notification
                                                              │
   [Host app] <─ insert text ─ [Keyboard ext] <───────────────┘
```

Cross-process channel: `Shared/AppGroupBridge.swift` — App Group container files + Darwin notifications.

## Layout

```
ios/
  App/                  Container SwiftUI app + recording engine
    VoiceInputApp.swift
    ContentView.swift
    RecordingEngine.swift
    RecordingView.swift
    SettingsView.swift
    Info.plist
  Keyboard/             Keyboard extension (bounces; no mic)
    KeyboardViewController.swift
    MicKeyboardView.swift
    Info.plist
  Shared/               Shared by both targets
    AppGroupBridge.swift
    SharedSettings.swift
  Entitlements/
    App.entitlements        com.apple.security.application-groups
    Keyboard.entitlements   com.apple.security.application-groups
  project.yml
  Makefile
```

## Setup

```bash
brew install xcodegen
cd ios
make open
```

In Xcode:

1. Select both targets → **Signing & Capabilities** → pick your team.
2. Create an App Group `group.ca.nextagent.voiceinput.shared` in the Apple Developer portal and add it to both targets (already referenced in the entitlements files).
3. Build & Run the `VoiceInputiOS` scheme on a real device (the simulator cannot grant keyboard Full Access in a realistic way).

## Trying on iPhone (TestFlight)

1. Apple Developer Program membership ($99/yr).
2. `Product → Archive` in Xcode with the `VoiceInputiOS` scheme.
3. Organizer → **Distribute App → App Store Connect → Upload**.
4. On App Store Connect, enable the build for **TestFlight** and create a **public link**.
5. Testers install the TestFlight app, tap the link, and receive the build. Re-archive within 90 days to refresh.

## First-run on the test device

1. Open **VoiceInput** app → grant Microphone + Speech permission.
2. Open **Settings → General → Keyboards → Keyboards → Add New Keyboard → VoiceInput**.
3. Tap the newly-added **VoiceInput** row → enable **Allow Full Access**.
4. In any app, tap the globe key → pick **VoiceInput** → tap the mic button → speak in the container app → swipe back.

## Known gaps vs. macOS version

- Cloud STT and LLM refinement are wired into Settings but not yet routed in the recording engine — Apple Speech only for v0.1.
- Vocabulary DB / contextual strings not ported (extension memory budget ~60 MB).
- No streaming partial display *inside* the keyboard view yet — the container shows it during recording.
- Auto-return to host app after recording is not possible on iOS without private APIs; user swipes back manually after stopping.
- Speaker diarization not implemented.
