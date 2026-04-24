import Cocoa
import SwiftUI

// MARK: - Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "Voice Input Settings"
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                GroupBox(label: Label("Speech Engine", systemImage: "waveform")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Engine", selection: $settings.sttEngineType) {
                            ForEach(STTEngineType.allCases, id: \.self) { type in
                                VStack(alignment: .leading) {
                                    Text(type.displayName)
                                }
                                .tag(type)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(settings.sttEngineType.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                if settings.sttEngineType == .cloud {
                    GroupBox(label: Label("Cloud API", systemImage: "cloud")) {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledField("Endpoint", text: $settings.sttEndpoint, placeholder: "https://stt.example.com/v1/audio/transcriptions")
                            LabeledSecureField("API Key", text: $settings.sttAPIKey, placeholder: "Your API key")

                            HStack {
                                Button("Test Connection") { testConnection() }
                                    .disabled(isTesting || settings.sttEndpoint.isEmpty || settings.sttAPIKey.isEmpty)
                                if isTesting { ProgressView().controlSize(.small) }
                                if !testResult.isEmpty {
                                    Text(testResult)
                                        .font(.caption)
                                        .foregroundColor(testResult.contains("OK") ? .green : .red)
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                if settings.sttEngineType == .whisper {
                    GroupBox(label: Label("Local Whisper", systemImage: "desktopcomputer")) {
                        Text("Local Whisper engine will be available in a future update. Please select Apple (Local) or Cloud API for now.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }

                GroupBox(label: Label("Language", systemImage: "globe")) {
                    Picker("Recognition Language", selection: $settings.selectedLanguage) {
                        ForEach(AppSettings.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(8)
                }

                GroupBox(label: Label("Behavior", systemImage: "gear")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Auto Send after transcription", isOn: $settings.autoSend)
                        if settings.autoSend {
                            HStack {
                                Text("Send Key")
                                    .frame(width: 80, alignment: .trailing)
                                Picker("", selection: $settings.sendKey) {
                                    ForEach(SendKeyType.allCases, id: \.self) { key in
                                        Text(key.displayName).tag(key)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }
                            Text("While LLM is refining, press Esc or Cmd+. to cancel. The LLM processing time is your cancel window — no extra delay needed.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox(label: Label("LLM Refinement", systemImage: "sparkles")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable LLM text refinement", isOn: $settings.llmEnabled)
                        if settings.llmEnabled {
                            LabeledField("API Base URL", text: $settings.llmBaseURL, placeholder: "https://api.openai.com/v1")
                            LabeledSecureField("API Key", text: $settings.llmAPIKey, placeholder: "sk-...")
                            LabeledField("Model", text: $settings.llmModel, placeholder: "gpt-4o-mini")
                        }
                    }
                    .padding(8)
                }

                SessionLoggingSection()

                LearningAgentSection()

                AppProfilesSection()

                GroupBox(label: Label("How to Use", systemImage: "keyboard")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hold **Fn** to record, release to transcribe.")
                        Text("While the LLM is refining: **Esc** or **Cmd+.** cancels the whole thing (no paste).")
                        Text("If a cached result was wrong: menu → **Forget Last Correction**.")
                    }
                    .font(.caption)
                    .padding(8)
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 700)
    }

    private func testConnection() {
        isTesting = true; testResult = ""
        Task {
            let r = await testSTT()
            await MainActor.run { testResult = r; isTesting = false }
        }
    }

    private func testSTT() async -> String {
        let base = settings.sttEndpoint.replacingOccurrences(of: "/v1/audio/transcriptions", with: "")
        guard let url = URL(string: "\(base)/health") else { return "Invalid URL" }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "OK" : "HTTP \(code)"
        } catch { return error.localizedDescription }
    }
}

// MARK: - Helper Views

struct LabeledField: View {
    let label: String; @Binding var text: String; let placeholder: String
    init(_ label: String, text: Binding<String>, placeholder: String) {
        self.label = label; self._text = text; self.placeholder = placeholder
    }
    var body: some View {
        HStack { Text(label).frame(width: 80, alignment: .trailing); TextField(placeholder, text: $text).textFieldStyle(.roundedBorder) }
    }
}

struct LabeledSecureField: View {
    let label: String; @Binding var text: String; let placeholder: String
    init(_ label: String, text: Binding<String>, placeholder: String) {
        self.label = label; self._text = text; self.placeholder = placeholder
    }
    var body: some View {
        HStack { Text(label).frame(width: 80, alignment: .trailing); SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder) }
    }
}

// MARK: - Session Logging Section

struct SessionLoggingSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newBlacklist: String = ""

    var body: some View {
        GroupBox(label: Label("Session History", systemImage: "clock.arrow.circlepath")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Record session history", isOn: $settings.sessionLoggingEnabled)
                Text("Stored locally at ~/.voiceinput/sessions.db. Never uploaded.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.sessionLoggingEnabled {
                    HStack {
                        Text("Retention")
                            .frame(width: 80, alignment: .trailing)
                        Picker("", selection: $settings.sessionRetentionDays) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("Forever").tag(0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        Button("Purge Now") {
                            SessionStore.shared.purgeOlderThan(days: settings.sessionRetentionDays)
                        }
                        .disabled(settings.sessionRetentionDays == 0)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Excluded apps (bundle IDs — never recorded):")
                            .font(.caption)
                        ForEach(settings.sessionBlacklist, id: \.self) { id in
                            HStack {
                                Text(id).font(.caption.monospaced())
                                Spacer()
                                Button(action: { removeBlacklist(id) }) {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.secondary)
                            }
                        }
                        HStack {
                            TextField("com.example.app", text: $newBlacklist)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                            Button("Add") { addBlacklist() }
                                .disabled(newBlacklist.isEmpty)
                        }
                    }
                }

                HStack {
                    Button("Open Sessions Window") {
                        SessionsWindowController.shared.show()
                    }
                    Spacer()
                }
            }
            .padding(8)
        }
    }

    private func addBlacklist() {
        let t = newBlacklist.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !settings.sessionBlacklist.contains(t) else { return }
        settings.sessionBlacklist.append(t)
        newBlacklist = ""
    }

    private func removeBlacklist(_ id: String) {
        settings.sessionBlacklist.removeAll { $0 == id }
    }
}

// MARK: - Learning Agent Section

struct LearningAgentSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var runs: [AgentRun] = []
    @State private var running = false

    var body: some View {
        GroupBox(label: Label("Learning Agent", systemImage: "brain.head.profile")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-learn from recent sessions", isOn: $settings.agentAutoLearnEnabled)
                Text("The agent analyzes your past voice input logs and teaches the LLM cache recurring corrections + your personal vocabulary. Runs in the background every ~20 new utterances.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("Run Now") {
                        running = true
                        Task {
                            await LearningAgent.shared.runL2(reason: "manual")
                            await MainActor.run {
                                running = false
                                reload()
                            }
                        }
                    }
                    .disabled(running || !settings.isLLMConfigured)
                    if running { ProgressView().controlSize(.small) }
                    if !settings.isLLMConfigured {
                        Text("Requires LLM configured above.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !runs.isEmpty {
                    Divider()
                    Text("Recent Runs")
                        .font(.caption)
                        .fontWeight(.semibold)
                    ForEach(runs, id: \.id) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(run.runAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption.monospacedDigit())
                                Text("[\(run.tier)]")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("+\(run.correctionsAdded) / +\(run.vocabAdded)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let s = run.summary {
                                Text(s)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(8)
        }
        .onAppear { reload() }
    }

    private func reload() {
        runs = SessionStore.shared.recentAgentRuns(limit: 5)
    }
}

// MARK: - App Profiles Section

struct AppProfilesSection: View {
    @State private var profiles: [AppProfile] = []
    @State private var runningApps: [(bundleID: String, name: String)] = []
    @State private var selectedAddID: String = ""

    var body: some View {
        GroupBox(label: Label("App Profiles", systemImage: "app.badge")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Per-app send key and auto-send override. Default for unknown apps uses Behavior settings above.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if profiles.isEmpty {
                    Text("No profiles. Click Reset to add built-in defaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 4) {
                        ForEach(profiles, id: \.bundleID) { profile in
                            AppProfileRow(profile: profile, onChange: { reload() })
                        }
                    }
                }

                Divider()

                HStack {
                    Picker("Add running app", selection: $selectedAddID) {
                        Text("Select running app…").tag("")
                        ForEach(runningApps.filter { app in !profiles.contains { $0.bundleID == app.bundleID } }, id: \.bundleID) { app in
                            Text(app.name).tag(app.bundleID)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Add") {
                        addSelected()
                    }
                    .disabled(selectedAddID.isEmpty)

                    Spacer()

                    Button("Reset to Defaults") {
                        AppProfileStore.shared.resetToDefaults()
                        reload()
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            reload()
            loadRunningApps()
        }
    }

    private func reload() {
        profiles = AppProfileStore.shared.allProfiles()
    }

    private func loadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (id, name)
            }
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
    }

    private func addSelected() {
        guard !selectedAddID.isEmpty,
              let app = runningApps.first(where: { $0.bundleID == selectedAddID }) else { return }
        AppProfileStore.shared.upsert(AppProfile(
            bundleID: app.bundleID,
            displayName: app.name,
            sendKey: AppSettings.shared.sendKey,
            autoSend: AppSettings.shared.autoSend
        ))
        selectedAddID = ""
        reload()
    }
}

struct AppProfileRow: View {
    let profile: AppProfile
    let onChange: () -> Void

    @State private var sendKey: SendKeyType
    @State private var autoSend: Bool

    init(profile: AppProfile, onChange: @escaping () -> Void) {
        self.profile = profile
        self.onChange = onChange
        _sendKey = State(initialValue: profile.sendKey)
        _autoSend = State(initialValue: profile.autoSend)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(profile.displayName)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Picker("", selection: $sendKey) {
                ForEach(SendKeyType.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .onChange(of: sendKey) { _, newValue in
                save(sendKey: newValue, autoSend: autoSend)
            }

            Toggle("Auto", isOn: $autoSend)
                .toggleStyle(.checkbox)
                .onChange(of: autoSend) { _, newValue in
                    save(sendKey: sendKey, autoSend: newValue)
                }

            Spacer()

            Button(action: {
                AppProfileStore.shared.remove(bundleID: profile.bundleID)
                onChange()
            }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
        .font(.caption)
    }

    private func save(sendKey: SendKeyType, autoSend: Bool) {
        var updated = profile
        updated.sendKey = sendKey
        updated.autoSend = autoSend
        AppProfileStore.shared.upsert(updated)
    }
}
