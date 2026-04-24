import Foundation
import Cocoa

final class AppSettings: NSObject, ObservableObject {
    static let shared = AppSettings()

    // MARK: - STT Engine
    @Published var sttEngineType: STTEngineType {
        didSet { UserDefaults.standard.set(sttEngineType.rawValue, forKey: "sttEngineType") }
    }

    @Published var sttEndpoint: String {
        didSet { UserDefaults.standard.set(sttEndpoint, forKey: "sttEndpoint") }
    }

    @Published var sttAPIKey: String {
        didSet { UserDefaults.standard.set(sttAPIKey, forKey: "sttAPIKey") }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

    // MARK: - LLM Settings
    @Published var llmEnabled: Bool {
        didSet { UserDefaults.standard.set(llmEnabled, forKey: "llmEnabled") }
    }

    @Published var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: "llmBaseURL") }
    }

    @Published var llmAPIKey: String {
        didSet { UserDefaults.standard.set(llmAPIKey, forKey: "llmAPIKey") }
    }

    @Published var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llmModel") }
    }

    // MARK: - Behavior
    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: "autoSend") }
    }

    @Published var sendKey: SendKeyType {
        didSet { UserDefaults.standard.set(sendKey.rawValue, forKey: "sendKey") }
    }

    /// Delay between pasting text and simulating Enter/Cmd+Enter.
    /// User can press Esc / Cmd+. during this window to cancel the send.
    @Published var autoSendDelay: TimeInterval {
        didSet { UserDefaults.standard.set(autoSendDelay, forKey: "autoSendDelay") }
    }

    // MARK: - Learning Agent
    @Published var agentAutoLearnEnabled: Bool {
        didSet { UserDefaults.standard.set(agentAutoLearnEnabled, forKey: "agentAutoLearnEnabled") }
    }

    // MARK: - Session Logging
    @Published var sessionLoggingEnabled: Bool {
        didSet { UserDefaults.standard.set(sessionLoggingEnabled, forKey: "sessionLoggingEnabled") }
    }

    /// Days of session history to retain. 0 = forever.
    @Published var sessionRetentionDays: Int {
        didSet { UserDefaults.standard.set(sessionRetentionDays, forKey: "sessionRetentionDays") }
    }

    /// Bundle IDs never logged (password managers, banking apps, etc.).
    @Published var sessionBlacklist: [String] {
        didSet { UserDefaults.standard.set(sessionBlacklist, forKey: "sessionBlacklist") }
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
        case .cloud: return !sttEndpoint.isEmpty && !sttAPIKey.isEmpty
        case .whisper: return false
        }
    }

    var isLLMConfigured: Bool {
        llmEnabled && !llmBaseURL.isEmpty && !llmAPIKey.isEmpty
    }

    // MARK: - Init
    private override init() {
        let d = UserDefaults.standard
        self.sttEngineType = STTEngineType(rawValue: d.string(forKey: "sttEngineType") ?? "") ?? .apple
        self.sttEndpoint = d.string(forKey: "sttEndpoint") ?? ""
        self.sttAPIKey = d.string(forKey: "sttAPIKey") ?? ""
        self.selectedLanguage = d.string(forKey: "selectedLanguage") ?? "zh"
        self.autoSend = d.object(forKey: "autoSend") == nil ? false : d.bool(forKey: "autoSend")
        self.sendKey = SendKeyType(rawValue: d.string(forKey: "sendKey") ?? "") ?? .enter
        // Default 0 — LLM processing itself provides the Esc cancel window.
        self.autoSendDelay = d.object(forKey: "autoSendDelay") == nil ? 0.0 : d.double(forKey: "autoSendDelay")
        self.sessionLoggingEnabled = d.object(forKey: "sessionLoggingEnabled") == nil ? true : d.bool(forKey: "sessionLoggingEnabled")
        self.agentAutoLearnEnabled = d.object(forKey: "agentAutoLearnEnabled") == nil ? true : d.bool(forKey: "agentAutoLearnEnabled")
        self.sessionRetentionDays = d.object(forKey: "sessionRetentionDays") == nil ? 30 : d.integer(forKey: "sessionRetentionDays")
        self.sessionBlacklist = d.stringArray(forKey: "sessionBlacklist") ?? AppSettings.defaultSessionBlacklist
        self.llmEnabled = d.object(forKey: "llmEnabled") == nil ? true : d.bool(forKey: "llmEnabled")
        self.llmBaseURL = d.string(forKey: "llmBaseURL") ?? ""
        self.llmAPIKey = d.string(forKey: "llmAPIKey") ?? ""
        self.llmModel = d.string(forKey: "llmModel") ?? ""
        super.init()
    }
}
