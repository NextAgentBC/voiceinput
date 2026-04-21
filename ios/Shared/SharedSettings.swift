import Foundation

/// Settings shared between the container app and the keyboard extension via App Group UserDefaults.
///
/// The container app writes; the keyboard reads. All keys live under a single suite so both targets
/// see identical values the moment the user changes them in Settings.
public struct SharedSettings {
    public static let appGroupID = "group.com.voiceinput.shared"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    // MARK: - Keys

    private enum Keys {
        static let engine = "engine"           // "apple" | "cloud"
        static let language = "language"       // "zh-CN" | "en-US" | "ja-JP" | "ko-KR"
        static let cloudURL = "cloudURL"
        static let cloudAPIKey = "cloudAPIKey"
        static let autoInsertSpace = "autoInsertSpace"
    }

    // MARK: - Accessors

    public static var engine: String {
        get { defaults.string(forKey: Keys.engine) ?? "apple" }
        set { defaults.set(newValue, forKey: Keys.engine) }
    }

    public static var language: String {
        get { defaults.string(forKey: Keys.language) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    public static var cloudURL: String {
        get { defaults.string(forKey: Keys.cloudURL) ?? "" }
        set { defaults.set(newValue, forKey: Keys.cloudURL) }
    }

    public static var cloudAPIKey: String {
        get { defaults.string(forKey: Keys.cloudAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.cloudAPIKey) }
    }

    public static var autoInsertSpace: Bool {
        get { defaults.bool(forKey: Keys.autoInsertSpace) }
        set { defaults.set(newValue, forKey: Keys.autoInsertSpace) }
    }
}
