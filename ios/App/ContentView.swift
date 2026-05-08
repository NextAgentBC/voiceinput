import SwiftUI
import Speech
import AVFoundation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var micStatus: AVAudioSession.RecordPermission = .undetermined
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var showingRecording = false
    @State private var testRequestID: UUID = UUID()
    @State private var testLanguage = "zh-CN"
    @State private var showMalformedAlert = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                appHeaderSection
                permissionsSection
                checklistSection
                testSection
                howItWorksSection
                Section {
                    NavigationLink("Settings", destination: SettingsView())
                }
            }
            .navigationTitle("VoiceInput")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
        .onAppear(perform: refreshPermissions)
        .fullScreenCover(isPresented: $showingRecording) {
            RecordingView(requestID: testRequestID, language: testLanguage)
        }
        .alert("Invalid recording request", isPresented: $showMalformedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The URL could not be parsed as a valid recording request.")
        }
    }

    // MARK: - Sections

    private var appHeaderSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceInput")
                        .font(.headline)
                    Text("Speech-to-text keyboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(
                title: "Microphone",
                status: micPermissionLabel,
                isDenied: micStatus == .denied
            ) {
                requestMic()
            }

            PermissionRow(
                title: "Speech Recognition",
                status: speechPermissionLabel,
                isDenied: speechStatus == .denied || speechStatus == .restricted
            ) {
                requestSpeech()
            }
        }
    }

    private var checklistSection: some View {
        Section("Setup Checklist") {
            ChecklistRow(
                number: "1",
                title: "Grant Microphone access",
                subtitle: micPermissionLabel,
                done: micStatus == .granted
            )
            ChecklistRow(
                number: "2",
                title: "Grant Speech Recognition access",
                subtitle: speechPermissionLabel,
                done: speechStatus == .authorized
            )
            ChecklistRow(
                number: "3",
                title: "Add VoiceInput Keyboard",
                subtitle: "Settings → General → Keyboards → Add New Keyboard → VoiceInput",
                done: false
            )
            ChecklistRow(
                number: "4",
                title: "Enable Full Access",
                subtitle: "Tap VoiceInput → toggle Allow Full Access",
                done: false
            )
        }
    }

    private var testSection: some View {
        Section("Test") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Language", selection: $testLanguage) {
                    Text("Chinese (Simplified)").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                    Text("Japanese").tag("ja-JP")
                    Text("Spanish").tag("es-ES")
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)

            Button {
                launchTestRecording()
            } label: {
                HStack {
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("Test Recording")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private var howItWorksSection: some View {
        Section("How It Works") {
            Text("Tap the mic key in the VoiceInput keyboard → your device opens this app and records audio. When you tap Stop, the transcription is written to a shared container and pasted into the text field when you switch back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func refreshPermissions() {
        micStatus = AVAudioSession.sharedInstance().recordPermission
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func requestMic() {
        switch micStatus {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { self.micStatus = granted ? .granted : .denied }
            }
        case .denied:
            openSystemSettings()
        default:
            break
        }
    }

    private func requestSpeech() {
        switch speechStatus {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { self.speechStatus = status }
            }
        case .denied, .restricted:
            openSystemSettings()
        default:
            break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func launchTestRecording() {
        testRequestID = UUID()
        AppGroupBridge.clearResult()
        let req = AppGroupBridge.RecordRequest(
            id: testRequestID,
            createdAt: Date(),
            language: testLanguage,
            hostBundleID: nil
        )
        AppGroupBridge.writeRequest(req)
        AppGroupBridge.post(AppGroupBridge.didStartRequestNotification)
        showingRecording = true
    }

    // MARK: - Helpers

    private var micPermissionLabel: String {
        switch micStatus {
        case .granted: return "Granted"
        case .denied: return "Denied — tap to open Settings"
        case .undetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    private var speechPermissionLabel: String {
        switch speechStatus {
        case .authorized: return "Granted"
        case .denied: return "Denied — tap to open Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let title: String
    let status: String
    let isDenied: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isDenied ? .red : .secondary)
            }
            Spacer()
            if isDenied {
                Button("Settings") { action() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            } else {
                Button("Grant") { action() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Checklist Row

private struct ChecklistRow: View {
    let number: String
    let title: String
    let subtitle: String
    let done: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(done ? "✓" : number)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(done ? .green : .secondary)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
