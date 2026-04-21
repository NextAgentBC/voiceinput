import SwiftUI
import Speech
import AVFoundation

/// Container app landing screen.
///
/// Purpose: walk first-time users through the three setup steps required before the keyboard
/// extension can actually transcribe speech — microphone permission, speech recognition
/// permission, and enabling the keyboard with Full Access in iOS Settings.
struct ContentView: View {
    @State private var micAuthorized = false
    @State private var speechAuthorized = false

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    SetupRow(
                        title: "Microphone access",
                        subtitle: micAuthorized ? "Granted" : "Tap to grant",
                        done: micAuthorized,
                        action: requestMic
                    )
                    SetupRow(
                        title: "Speech recognition",
                        subtitle: speechAuthorized ? "Granted" : "Tap to grant",
                        done: speechAuthorized,
                        action: requestSpeech
                    )
                    SetupRow(
                        title: "Enable keyboard",
                        subtitle: "Settings → General → Keyboards → Add → VoiceInput → enable Full Access",
                        done: false,
                        action: openSettings
                    )
                }

                Section("Configuration") {
                    NavigationLink("Settings") { SettingsView() }
                }

                Section {
                    Text("After setup, switch to the VoiceInput keyboard in any app by long-pressing the 🌐 globe key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VoiceInput")
            .onAppear(perform: refreshPermissions)
        }
    }

    private func refreshPermissions() {
        micAuthorized = AVAudioSession.sharedInstance().recordPermission == .granted
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func requestMic() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { micAuthorized = granted }
        }
    }

    private func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { speechAuthorized = (status == .authorized) }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct SetupRow: View {
    let title: String
    let subtitle: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(done ? .green : .secondary)
            }
        }
    }
}
