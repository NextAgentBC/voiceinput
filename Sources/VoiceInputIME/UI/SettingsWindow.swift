import Cocoa
import SwiftUI

// MARK: - Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Voice Input Settings"
        w.minSize = NSSize(width: 640, height: 480)
        w.contentView = NSHostingView(rootView: SettingsRootView())
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Root View

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            EngineTab()
                .tabItem { Label("Engine", systemImage: "waveform") }

            PerAppTab()
                .tabItem { Label("Per-app", systemImage: "app.badge") }

            VocabTab()
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }

            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: - Permissions Section

struct PermissionsSection: View {
    @State private var micStatus: PermissionsManager.Status = .undetermined
    @State private var speechStatus: PermissionsManager.Status = .undetermined
    @State private var axStatus: PermissionsManager.Status = .undetermined

    var body: some View {
        GroupBox(label: Label("Permissions", systemImage: "lock.shield")) {
            VStack(alignment: .leading, spacing: 8) {
                PermissionRow(label: "Microphone", status: micStatus) {
                    PermissionsManager.openSystemSettings(for: .microphone)
                }
                PermissionRow(label: "Speech Recognition", status: speechStatus) {
                    PermissionsManager.openSystemSettings(for: .speechRecognition)
                }
                PermissionRow(label: "Accessibility", status: axStatus) {
                    PermissionsManager.openSystemSettings(for: .accessibility)
                }
            }
            .padding(8)
        }
        .onAppear { refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        micStatus    = PermissionsManager.microphoneStatus()
        speechStatus = PermissionsManager.speechRecognitionStatus()
        axStatus     = PermissionsManager.accessibilityStatus()
    }
}

struct PermissionRow: View {
    let label: String
    let status: PermissionsManager.Status
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 160, alignment: .leading)
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            case .denied:
                Label("Denied", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                Button("Open System Settings", action: openSettings)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
            case .undetermined:
                Text("Not determined")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
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
                            let days = settings.sessionRetentionDays
                            let confirmed = ConfirmAlert.destructive(
                                title: "Purge sessions older than \(days) days?",
                                message: "This will permanently delete old session history. This cannot be undone.",
                                confirmTitle: "Purge"
                            )
                            if confirmed {
                                SessionStore.shared.purgeOlderThan(days: days)
                            }
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
                        Text("Requires LLM configured in Engine tab.")
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
                                Text(DateFormat.timeOfDay(run.runAt))
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
