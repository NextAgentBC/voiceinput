import Foundation
import Cocoa

// MARK: - Settings storage struct

private struct VoiceInputSettings: Codable {
    var sttEngineType: STTEngineType = .apple
    var sttEndpoint: String = ""
    var selectedLanguage: String = "zh"
    var autoSend: Bool = false
    var sendKey: SendKeyType = .enter
    var autoSendDelay: TimeInterval = 0.0
    var llmEnabled: Bool = true
    var llmBaseURL: String = ""
    var llmModel: String = ""
    var agentAutoLearnEnabled: Bool = true
    var sessionLoggingEnabled: Bool = true
    var sessionRetentionDays: Int = 30
    var sessionBlacklist: [String] = AppSettings.defaultSessionBlacklist
    var audioCaptureEnabled: Bool = false
    var audioCaptureFolderPath: String = ""
    /// Model identifier sent in the `model` multipart field for Cloud STT.
    /// Required by some self-hosted endpoints (Qwen3-ASR via credbroker, etc.).
    /// Empty string = don't send the field.
    var sttModel: String = ""
    var llmPolishMode: Bool = false
}

// MARK: - AppSettings

final class AppSettings: NSObject, ObservableObject {
    static let shared = AppSettings()

    // MARK: - Keychain-backed (unchanged from PR1)

    @Published var sttAPIKey: String {
        didSet { SecureStore.set("sttAPIKey", sttAPIKey) }
    }

    @Published var llmAPIKey: String {
        didSet { SecureStore.set("llmAPIKey", llmAPIKey) }
    }

    // MARK: - Non-secret properties backed by VoiceInputSettings

    @Published var sttEngineType: STTEngineType {
        didSet { mutate { $0.sttEngineType = sttEngineType } }
    }

    @Published var sttEndpoint: String {
        didSet { mutate { $0.sttEndpoint = sttEndpoint } }
    }

    @Published var selectedLanguage: String {
        didSet { mutate { $0.selectedLanguage = selectedLanguage } }
    }

    @Published var autoSend: Bool {
        didSet { mutate { $0.autoSend = autoSend } }
    }

    @Published var sendKey: SendKeyType {
        didSet { mutate { $0.sendKey = sendKey } }
    }

    /// Delay between pasting text and simulating Enter/Cmd+Enter.
    /// User can press Esc / Cmd+. during this window to cancel the send.
    @Published var autoSendDelay: TimeInterval {
        didSet { mutate { $0.autoSendDelay = autoSendDelay } }
    }

    @Published var llmEnabled: Bool {
        didSet { mutate { $0.llmEnabled = llmEnabled } }
    }

    @Published var llmBaseURL: String {
        didSet { mutate { $0.llmBaseURL = llmBaseURL } }
    }

    @Published var llmModel: String {
        didSet { mutate { $0.llmModel = llmModel } }
    }

    @Published var agentAutoLearnEnabled: Bool {
        didSet { mutate { $0.agentAutoLearnEnabled = agentAutoLearnEnabled } }
    }

    @Published var sessionLoggingEnabled: Bool {
        didSet { mutate { $0.sessionLoggingEnabled = sessionLoggingEnabled } }
    }

    /// Days of session history to retain. 0 = forever.
    @Published var sessionRetentionDays: Int {
        didSet { mutate { $0.sessionRetentionDays = sessionRetentionDays } }
    }

    /// Bundle IDs never logged (password managers, banking apps, etc.).
    @Published var sessionBlacklist: [String] {
        didSet { mutate { $0.sessionBlacklist = sessionBlacklist } }
    }

    /// When true, `AudioRecorder` runs continuously and saves a fresh
    /// `.wav` to `audioCaptureFolderPath` every minute. Independent of
    /// the dictation hotkey.
    @Published var audioCaptureEnabled: Bool {
        didSet { mutate { $0.audioCaptureEnabled = audioCaptureEnabled } }
    }

    /// Absolute filesystem path where the rolling audio chunks land.
    /// Empty string = unconfigured; toggling on without a folder is a no-op.
    @Published var audioCaptureFolderPath: String {
        didSet { mutate { $0.audioCaptureFolderPath = audioCaptureFolderPath } }
    }

    /// Identifier sent in the multipart `model` field of Cloud STT requests
    /// (and the meeting-notes transcriber). Self-hosted Qwen3-ASR via
    /// credbroker requires `Qwen/Qwen3-ASR-1.7B`; OpenAI Whisper accepts
    /// `whisper-1`. Empty = don't send the field.
    @Published var sttModel: String {
        didSet { mutate { $0.sttModel = sttModel } }
    }

    /// When true, the LLM refiner is allowed to restructure transcribed
    /// text — paragraph breaks, bullet lists, light prose editing.
    /// When false (default) it stays in conservative mode: only fix obvious
    /// STT errors, never rewrite.
    @Published var llmPolishMode: Bool {
        didSet { mutate { $0.llmPolishMode = llmPolishMode } }
    }

    static let defaultSessionBlacklist = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
    ]

    // MARK: - Constants
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh", "简体中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    var isSTTConfigured: Bool {
        switch sttEngineType {
        case .apple: return true
        // API key is optional — credbroker / private endpoints inject auth
        // server-side, so we only require the endpoint URL.
        case .cloud: return !sttEndpoint.isEmpty
        case .whisper: return false
        }
    }

    var isLLMConfigured: Bool {
        // API key optional — credbroker / private endpoints inject auth.
        llmEnabled && !llmBaseURL.isEmpty
    }

    // MARK: - Storage

    private static let blobKey = "voiceInputSettingsV1"
    private static let migrationFlagKey = "appSettingsConsolidatedV1"
    private var _settings: VoiceInputSettings

    private func mutate(_ f: (inout VoiceInputSettings) -> Void) {
        f(&_settings)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(_settings) else { return }
        UserDefaults.standard.set(data, forKey: AppSettings.blobKey)
    }

    // MARK: - Init

    private override init() {
        let d = UserDefaults.standard

        // Load or migrate settings blob.
        var settings: VoiceInputSettings
        if let data = d.data(forKey: AppSettings.blobKey),
           let decoded = try? JSONDecoder().decode(VoiceInputSettings.self, from: data) {
            settings = decoded
        } else {
            settings = VoiceInputSettings()
        }

        // One-shot migration from legacy per-key UserDefaults (runs once).
        if !d.bool(forKey: AppSettings.migrationFlagKey) {
            if let v = d.string(forKey: "sttEngineType").flatMap(STTEngineType.init(rawValue:)) { settings.sttEngineType = v }
            if let v = d.string(forKey: "sttEndpoint") { settings.sttEndpoint = v }
            if let v = d.string(forKey: "selectedLanguage") { settings.selectedLanguage = v }
            if d.object(forKey: "autoSend") != nil { settings.autoSend = d.bool(forKey: "autoSend") }
            if let v = d.string(forKey: "sendKey").flatMap(SendKeyType.init(rawValue:)) { settings.sendKey = v }
            if d.object(forKey: "autoSendDelay") != nil { settings.autoSendDelay = d.double(forKey: "autoSendDelay") }
            if d.object(forKey: "llmEnabled") != nil { settings.llmEnabled = d.bool(forKey: "llmEnabled") }
            if let v = d.string(forKey: "llmBaseURL") { settings.llmBaseURL = v }
            if let v = d.string(forKey: "llmModel") { settings.llmModel = v }
            if d.object(forKey: "agentAutoLearnEnabled") != nil { settings.agentAutoLearnEnabled = d.bool(forKey: "agentAutoLearnEnabled") }
            if d.object(forKey: "sessionLoggingEnabled") != nil { settings.sessionLoggingEnabled = d.bool(forKey: "sessionLoggingEnabled") }
            if d.object(forKey: "sessionRetentionDays") != nil { settings.sessionRetentionDays = d.integer(forKey: "sessionRetentionDays") }
            if let v = d.stringArray(forKey: "sessionBlacklist") { settings.sessionBlacklist = v }
            // Legacy keys left in place for rollback; flag prevents re-migration.
            d.set(true, forKey: AppSettings.migrationFlagKey)
        }

        _settings = settings

        // Keychain values.
        self.sttAPIKey = SecureStore.get("sttAPIKey") ?? ""
        self.llmAPIKey = SecureStore.get("llmAPIKey") ?? ""

        // Unpack struct into @Published properties.
        self.sttEngineType = settings.sttEngineType
        self.sttEndpoint = settings.sttEndpoint
        self.selectedLanguage = settings.selectedLanguage
        self.autoSend = settings.autoSend
        self.sendKey = settings.sendKey
        self.autoSendDelay = settings.autoSendDelay
        self.llmEnabled = settings.llmEnabled
        self.llmBaseURL = settings.llmBaseURL
        self.llmModel = settings.llmModel
        self.agentAutoLearnEnabled = settings.agentAutoLearnEnabled
        self.sessionLoggingEnabled = settings.sessionLoggingEnabled
        self.sessionRetentionDays = settings.sessionRetentionDays
        self.sessionBlacklist = settings.sessionBlacklist
        self.audioCaptureEnabled = settings.audioCaptureEnabled
        self.audioCaptureFolderPath = settings.audioCaptureFolderPath
        self.sttModel = settings.sttModel
        self.llmPolishMode = settings.llmPolishMode

        super.init()

        // Persist freshly migrated blob.
        persist()

        // One-shot migration: move plaintext keys from UserDefaults → Keychain.
        if !d.bool(forKey: "apiKeysMigratedToKeychainV1") {
            if let oldSTT = d.string(forKey: "sttAPIKey"), !oldSTT.isEmpty, sttAPIKey.isEmpty {
                SecureStore.set("sttAPIKey", oldSTT)
                sttAPIKey = oldSTT
            }
            if let oldLLM = d.string(forKey: "llmAPIKey"), !oldLLM.isEmpty, llmAPIKey.isEmpty {
                SecureStore.set("llmAPIKey", oldLLM)
                llmAPIKey = oldLLM
            }
            d.removeObject(forKey: "sttAPIKey")
            d.removeObject(forKey: "llmAPIKey")
            d.set(true, forKey: "apiKeysMigratedToKeychainV1")
        }
    }
}
