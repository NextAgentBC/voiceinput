import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SharedSettings.shared

    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Language", selection: $settings.language) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                Picker("Engine", selection: $settings.sttEngineType) {
                    Text("Apple (on-device)").tag("apple")
                    Text("Cloud").tag("cloud")
                }
            }

            if settings.sttEngineType == "cloud" {
                Section("Cloud STT") {
                    TextField("Endpoint URL", text: $settings.sttEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key (optional)", text: Binding(
                        get: { settings.sttAPIKey },
                        set: { settings.sttAPIKey = $0 }
                    ))
                    TextField("Model (optional)", text: $settings.sttModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use credbroker (Qwen3-ASR)") {
                        settings.sttEngineType = "cloud"
                        settings.sttEndpoint = "http://100.79.97.110:8800/v1/proxy/asr/v1/audio/transcriptions"
                        settings.sttModel = "Qwen/Qwen3-ASR-1.7B"
                    }
                }
            }

            Section {
                Toggle("Enable LLM refinement", isOn: $settings.llmEnabled)
                if settings.llmEnabled {
                    TextField("API Base URL", text: $settings.llmBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key (optional)", text: Binding(
                        get: { settings.llmAPIKey },
                        set: { settings.llmAPIKey = $0 }
                    ))
                    TextField("Model", text: $settings.llmModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Polish mode (auto-paragraph + bullets)", isOn: $settings.llmPolishMode)
                }
            } header: {
                Text("LLM")
            } footer: {
                Text(settings.llmPolishMode
                     ? "LLM restructures long dictation into paragraphs / bullets."
                     : "LLM only fixes obvious recognition errors.")
                    .font(.caption)
            }

            Section {
                Link("Open System Keyboard Settings",
                     destination: URL(string: UIApplication.openSettingsURLString)!)
            } header: {
                Text("Setup")
            } footer: {
                Text("After granting permissions, add the VoiceInput keyboard in System Settings and enable Allow Full Access.")
            }
        }
        .navigationTitle("Settings")
    }
}
