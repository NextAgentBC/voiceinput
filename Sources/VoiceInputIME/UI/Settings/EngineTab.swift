import SwiftUI

struct EngineTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var sttTestResult = ""
    @State private var sttIsTesting = false
    @State private var llmTestResult = ""
    @State private var llmIsTesting = false
    @State private var lastSTTError: String?
    @State private var lastSTTErrorDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                GroupBox(label: Label("Speech Engine", systemImage: "waveform")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Engine", selection: $settings.sttEngineType) {
                            ForEach(STTEngineType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
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
                            LabeledSecureField("API Key", text: $settings.sttAPIKey, placeholder: "Optional — leave empty if endpoint injects auth")
                            LabeledField("Model", text: $settings.sttModel, placeholder: "Optional — e.g. Qwen/Qwen3-ASR-1.7B or whisper-1")

                            HStack {
                                Button("Use credbroker (Qwen3-ASR)") { useCredbrokerPreset() }
                                    .help("Set endpoint to the local credbroker Qwen3-ASR proxy. Requires Tailscale connection to mainserver.")
                            }

                            HStack {
                                Button("Test Connection") { testSTTConnection() }
                                    .disabled(sttIsTesting || settings.sttEndpoint.isEmpty)
                                if sttIsTesting { ProgressView().controlSize(.small) }
                                if !sttTestResult.isEmpty {
                                    Text(sttTestResult)
                                        .font(.caption)
                                        .foregroundColor(sttTestResult.contains("OK") ? .green : .red)
                                }
                            }
                            if let errMsg = lastSTTError, let errDate = lastSTTErrorDate {
                                HStack(spacing: 4) {
                                    Text("Last error: \(errMsg)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    Text("·")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(DateFormat.ageShort(errDate))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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

                GroupBox(label: Label("LLM Refinement", systemImage: "sparkles")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable LLM text refinement", isOn: $settings.llmEnabled)
                        if settings.llmEnabled {
                            LabeledField("API Base URL", text: $settings.llmBaseURL, placeholder: "https://api.openai.com/v1")
                            LabeledSecureField("API Key", text: $settings.llmAPIKey, placeholder: "Optional")
                            LabeledField("Model", text: $settings.llmModel, placeholder: "gpt-4o-mini")

                            Toggle("Polish mode (auto-paragraph + bullet lists)", isOn: $settings.llmPolishMode)
                                .help("On: LLM restructures long dictation. Off: LLM only fixes obvious STT errors.")

                            HStack {
                                Button("Test Connection") { testLLMConnection() }
                                    .disabled(llmIsTesting || !settings.isLLMConfigured)
                                if llmIsTesting { ProgressView().controlSize(.small) }
                                if !llmTestResult.isEmpty {
                                    Text(llmTestResult)
                                        .font(.caption)
                                        .foregroundColor(llmTestResult.contains("OK") ? .green : .red)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceInputSTTError)) { note in
            if let msg = note.userInfo?["message"] as? String {
                lastSTTError = msg
                lastSTTErrorDate = Date()
            }
        }
    }

    private func useCredbrokerPreset() {
        settings.sttEngineType = .cloud
        settings.sttEndpoint = "http://100.79.97.110:8800/v1/proxy/asr/v1/audio/transcriptions"
        settings.sttModel = "Qwen/Qwen3-ASR-1.7B"
        // Broker auth is automatic via Tailscale identity — no client key.
        settings.sttAPIKey = ""
        sttTestResult = "Configured. Test to verify."
    }

    private func testSTTConnection() {
        sttIsTesting = true; sttTestResult = ""
        Task {
            let r = await runSTTTest()
            await MainActor.run { sttTestResult = r; sttIsTesting = false }
        }
    }

    private func runSTTTest() async -> String {
        let base = settings.sttEndpoint.replacingOccurrences(of: "/v1/audio/transcriptions", with: "")
        guard let url = URL(string: "\(base)/health") else { return "Invalid URL" }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "OK" : "HTTP \(code)"
        } catch { return error.localizedDescription }
    }

    private func testLLMConnection() {
        llmIsTesting = true; llmTestResult = ""
        Task {
            let r = await runLLMTest()
            await MainActor.run { llmTestResult = r; llmIsTesting = false }
        }
    }

    private func runLLMTest() async -> String {
        let base = settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models") else { return "Invalid URL" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if !settings.llmAPIKey.isEmpty {
            req.setValue("Bearer \(settings.llmAPIKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? "OK" : "HTTP \(code)"
        } catch { return error.localizedDescription }
    }
}
