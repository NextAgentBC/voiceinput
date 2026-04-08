import Foundation
import Cocoa

final class AppSettings: NSObject, ObservableObject {
    static let shared = AppSettings()

    // MARK: - STT Engine
    @Published var sttEngineType: STTEngineType {
        didSet { UserDefaults.standard.set(sttEngineType.rawValue, forKey: "sttEngineType") }
    }

    // MARK: - Cloud STT Settings (only used when engine = .cloud)
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

    // MARK: - Meeting Mode
    @Published var meetingModeAutoDetect: Bool {
        didSet { UserDefaults.standard.set(meetingModeAutoDetect, forKey: "meetingModeAutoDetect") }
    }

    @Published var meetingModeApps: [String] {
        didSet { UserDefaults.standard.set(meetingModeApps, forKey: "meetingModeApps") }
    }

    @Published var meetingSelfLabel: String {
        didSet { UserDefaults.standard.set(meetingSelfLabel, forKey: "meetingSelfLabel") }
    }

    // MARK: - Meeting Server (Tailscale)
    @Published var meetingServerEndpoint: String {
        didSet { UserDefaults.standard.set(meetingServerEndpoint, forKey: "meetingServerEndpoint") }
    }

    @Published var meetingNumSpeakers: Int {
        didSet { UserDefaults.standard.set(meetingNumSpeakers, forKey: "meetingNumSpeakers") }
    }

    @Published var meetingSummarize: Bool {
        didSet { UserDefaults.standard.set(meetingSummarize, forKey: "meetingSummarize") }
    }

    // MARK: - System Audio Capture
    @Published var captureSystemAudio: Bool {
        didSet { UserDefaults.standard.set(captureSystemAudio, forKey: "captureSystemAudio") }
    }

    // MARK: - Meeting Diarization
    @Published var meetingDiarization: Bool {
        didSet { UserDefaults.standard.set(meetingDiarization, forKey: "meetingDiarization") }
    }

    static let defaultMeetingModeApps = [
        "com.apple.Notes", "md.obsidian", "notion.id",
        "net.shinyfrog.bear", "com.luki.Craft", "abnerworks.Typora",
        "com.microsoft.onenote.mac"
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
        case .apple: return true  // Always ready
        case .cloud: return !sttEndpoint.isEmpty && !sttAPIKey.isEmpty
        case .whisper: return false  // Not yet available
        }
    }

    var isLLMConfigured: Bool {
        llmEnabled && !llmBaseURL.isEmpty && !llmAPIKey.isEmpty
    }

    var isMeetingServerConfigured: Bool {
        !meetingServerEndpoint.isEmpty
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
        self.llmEnabled = d.bool(forKey: "llmEnabled")
        self.llmBaseURL = d.string(forKey: "llmBaseURL") ?? ""
        self.llmAPIKey = d.string(forKey: "llmAPIKey") ?? ""
        self.llmModel = d.string(forKey: "llmModel") ?? ""
        // Meeting Mode
        self.meetingModeAutoDetect = d.object(forKey: "meetingModeAutoDetect") == nil ? true : d.bool(forKey: "meetingModeAutoDetect")
        self.meetingModeApps = d.stringArray(forKey: "meetingModeApps") ?? AppSettings.defaultMeetingModeApps
        self.meetingSelfLabel = d.string(forKey: "meetingSelfLabel") ?? "你"
        // Meeting Server
        self.meetingServerEndpoint = d.string(forKey: "meetingServerEndpoint") ?? ""
        self.meetingNumSpeakers = d.integer(forKey: "meetingNumSpeakers")
        self.meetingSummarize = d.object(forKey: "meetingSummarize") == nil ? true : d.bool(forKey: "meetingSummarize")
        // System Audio
        self.captureSystemAudio = d.bool(forKey: "captureSystemAudio")
        // Diarization
        self.meetingDiarization = d.bool(forKey: "meetingDiarization")
        super.init()
    }
}
