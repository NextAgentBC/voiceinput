import Cocoa
import SwiftUI

// MARK: - Window Controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
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

                // Engine Selector
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

                // Cloud API Settings (only when cloud selected)
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

                // Whisper notice
                if settings.sttEngineType == .whisper {
                    GroupBox(label: Label("Local Whisper", systemImage: "desktopcomputer")) {
                        Text("Local Whisper engine will be available in a future update. Please select Apple (Local) or Cloud API for now.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }

                // Language
                GroupBox(label: Label("Language", systemImage: "globe")) {
                    Picker("Recognition Language", selection: $settings.selectedLanguage) {
                        ForEach(AppSettings.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(8)
                }

                // Behavior
                GroupBox(label: Label("Behavior", systemImage: "gear")) {
                    Toggle("Auto Send (press Enter after paste)", isOn: $settings.autoSend)
                        .padding(8)
                }

                // LLM
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

                // How to use
                GroupBox(label: Label("How to Use", systemImage: "keyboard")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hold **Fn** key to record, release to transcribe.")
                        Text("Press **Escape** to cancel. **Cmd+Z** to undo.")
                    }
                    .font(.caption)
                    .padding(8)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 500)
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
