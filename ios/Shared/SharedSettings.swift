import Foundation
import Security
import os.log

// MARK: - KeychainBridge

/// Keychain read/write shared between the container app and (eventually) the keyboard extension.
///
/// For cross-process keychain sharing you must add a shared `keychain-access-groups` entitlement
/// (`$(AppIdentifierPrefix)com.voiceinput.shared`) to both targets and set `accessGroup` below.
/// TODO: add keychain-access-groups entitlement to App.entitlements + Keyboard.entitlements once
/// the Apple Developer portal entry exists. Until then, keys are stored in the container app's
/// own partition; the keyboard extension cannot read them (API keys aren't needed there yet).
public enum KeychainBridge {
    public static let service = "com.voiceinput.app.shared"
    /// Set to `"$(AppIdentifierPrefix)com.voiceinput.shared"` after adding entitlement.
    public static let accessGroup: String? = nil

    private static let log = Logger(subsystem: "com.voiceinput.app", category: "KeychainBridge")

    public static func get(_ account: String) -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let group = accessGroup { query[kSecAttrAccessGroup] = group }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                log.error("get \(account, privacy: .public) failed: \(status, privacy: .public)")
            }
            return nil
        }
        return value
    }

    public static func set(_ account: String, _ value: String?) {
        guard let value, !value.isEmpty else {
            delete(account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let group = accessGroup { query[kSecAttrAccessGroup] = group }

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // Accessible after first unlock so the keyboard extension can read without user interaction.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData] = data
            insertQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insertQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("set \(account, privacy: .public) failed: \(status, privacy: .public)")
        }
    }

    private static func delete(_ account: String) {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let group = accessGroup { query[kSecAttrAccessGroup] = group }

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("delete \(account, privacy: .public) failed: \(status, privacy: .public)")
        }
    }
}

// MARK: - SharedSettings

/// Observable settings shared between the container app and keyboard extension via App Group
/// UserDefaults. API keys are stored separately in the Keychain via `KeychainBridge`.
///
/// Both targets read from the same `UserDefaults(suiteName: AppGroupBridge.groupID)` suite, so
/// a change the user makes in the container app's Settings screen is immediately visible to the
/// keyboard extension without a restart.
@MainActor
public final class SharedSettings: ObservableObject {
    public static let shared = SharedSettings()

    private let defaults: UserDefaults

    // MARK: - Keys

    private enum Keys {
        static let language      = "language"
        static let sttEngineType = "sttEngineType"
        static let sttEndpoint   = "sttEndpoint"
        static let sttModel      = "sttModel"
        static let llmEnabled    = "llmEnabled"
        static let llmBaseURL    = "llmBaseURL"
        static let llmModel      = "llmModel"
        static let llmPolishMode = "llmPolishMode"
    }

    // MARK: - Init

    private init() {
        self.defaults = UserDefaults(suiteName: AppGroupBridge.groupID) ?? .standard
    }

    // MARK: - Recognition

    /// Recognition locale short code: "zh", "en", "ja", "ko".
    @Published public var language: String = "" {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    /// STT engine selection. "apple" = local SFSpeechRecognizer. "cloud" = HTTP endpoint.
    @Published public var sttEngineType: String = "" {
        didSet { defaults.set(sttEngineType, forKey: Keys.sttEngineType) }
    }

    // MARK: - Cloud STT

    /// Base URL of the Whisper-compatible transcription endpoint. Empty string disables cloud STT.
    @Published public var sttEndpoint: String = "" {
        didSet { defaults.set(sttEndpoint, forKey: Keys.sttEndpoint) }
    }

    /// Model identifier sent in the `model` form field (optional; leave empty to omit).
    @Published public var sttModel: String = "" {
        didSet { defaults.set(sttModel, forKey: Keys.sttModel) }
    }

    /// Cloud STT API key — stored in Keychain, not UserDefaults.
    /// Views that need reactivity should call `objectWillChange.send()` before mutating.
    public var sttAPIKey: String {
        get { KeychainBridge.get("sttAPIKey") ?? "" }
        set {
            objectWillChange.send()
            KeychainBridge.set("sttAPIKey", newValue)
        }
    }

    // MARK: - LLM Refinement

    /// Whether to send the raw transcript through LLM refinement before pasting.
    @Published public var llmEnabled: Bool = false {
        didSet { defaults.set(llmEnabled, forKey: Keys.llmEnabled) }
    }

    /// LLM API base URL (OpenAI-compatible).
    @Published public var llmBaseURL: String = "" {
        didSet { defaults.set(llmBaseURL, forKey: Keys.llmBaseURL) }
    }

    /// LLM model identifier, e.g. "gpt-4o-mini" or "Qwen/Qwen3-72B".
    @Published public var llmModel: String = "" {
        didSet { defaults.set(llmModel, forKey: Keys.llmModel) }
    }

    /// When true, LLM restructures long dictation into paragraphs / bullets.
    /// When false, LLM only fixes obvious recognition errors.
    @Published public var llmPolishMode: Bool = false {
        didSet { defaults.set(llmPolishMode, forKey: Keys.llmPolishMode) }
    }

    /// LLM API key — stored in Keychain, not UserDefaults.
    /// Views that need reactivity should call `objectWillChange.send()` before mutating.
    public var llmAPIKey: String {
        get { KeychainBridge.get("llmAPIKey") ?? "" }
        set {
            objectWillChange.send()
            KeychainBridge.set("llmAPIKey", newValue)
        }
    }

    // MARK: - Load from persisted store

    /// Pull current values from UserDefaults into Published properties.
    /// Called once at app launch so the UI reflects what was persisted.
    public func load() {
        language      = defaults.string(forKey: Keys.language)      ?? "zh"
        sttEngineType = defaults.string(forKey: Keys.sttEngineType) ?? "apple"
        sttEndpoint   = defaults.string(forKey: Keys.sttEndpoint)   ?? ""
        sttModel      = defaults.string(forKey: Keys.sttModel)      ?? ""
        llmEnabled    = defaults.bool(forKey: Keys.llmEnabled)
        llmBaseURL    = defaults.string(forKey: Keys.llmBaseURL)    ?? ""
        llmModel      = defaults.string(forKey: Keys.llmModel)      ?? ""
        llmPolishMode = defaults.bool(forKey: Keys.llmPolishMode)
    }
}
