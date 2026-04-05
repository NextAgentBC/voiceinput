import Foundation
import Cocoa

final class AppSettings: NSObject, ObservableObject {
    static let shared = AppSettings()

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

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

    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: "autoSend") }
    }

static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    var isLLMConfigured: Bool {
        llmEnabled && !llmBaseURL.isEmpty && !llmAPIKey.isEmpty && !llmModel.isEmpty
    }

    private override init() {
        let defaults = UserDefaults.standard
        self.selectedLanguage = defaults.string(forKey: "selectedLanguage") ?? "zh-CN"
        self.autoSend = defaults.object(forKey: "autoSend") == nil ? true : defaults.bool(forKey: "autoSend")
self.llmEnabled = defaults.bool(forKey: "llmEnabled")
        self.llmBaseURL = defaults.string(forKey: "llmBaseURL") ?? ""
        self.llmAPIKey = defaults.string(forKey: "llmAPIKey") ?? ""
        self.llmModel = defaults.string(forKey: "llmModel") ?? ""
        super.init()
    }

    // MARK: - Menu Actions

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        selectedLanguage = code
    }

    @objc func toggleAutoSend(_ sender: NSMenuItem) {
        autoSend = !autoSend
    }

@objc func toggleLLM(_ sender: NSMenuItem) {
        llmEnabled = !llmEnabled
    }

    @objc func editDictionary(_ sender: NSMenuItem) {
        let dictPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput/dictionary.json")
        NSWorkspace.shared.open(dictPath)
    }
}
