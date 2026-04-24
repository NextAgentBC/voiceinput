import Cocoa
import os.log

private let profileLog = Logger(subsystem: "com.voiceinput.app", category: "AppProfile")

/// Per-app behavior override: send key, whether to auto-send, delay.
struct AppProfile: Codable, Equatable {
    let bundleID: String
    var displayName: String
    var sendKey: SendKeyType
    var autoSend: Bool
    /// nil = use global setting
    var autoSendDelay: TimeInterval?

    init(bundleID: String, displayName: String, sendKey: SendKeyType = .enter, autoSend: Bool = true, autoSendDelay: TimeInterval? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.sendKey = sendKey
        self.autoSend = autoSend
        self.autoSendDelay = autoSendDelay
    }

    /// Effective delay (profile overrides global).
    func effectiveDelay(global: TimeInterval) -> TimeInterval {
        autoSendDelay ?? global
    }
}

/// Built-in defaults for popular chat / productivity apps.
enum BuiltInProfiles {
    static let all: [AppProfile] = [
        // Chat — Enter to send
        AppProfile(bundleID: "com.tencent.xinWeChat",        displayName: "WeChat",     sendKey: .enter),
        AppProfile(bundleID: "com.tencent.qq",                displayName: "QQ",         sendKey: .enter),
        AppProfile(bundleID: "org.telegram.desktop",          displayName: "Telegram",   sendKey: .enter),
        AppProfile(bundleID: "ru.keepcoder.Telegram",         displayName: "Telegram",   sendKey: .enter),
        AppProfile(bundleID: "com.apple.MobileSMS",           displayName: "Messages",   sendKey: .enter),
        AppProfile(bundleID: "com.hnc.Discord",               displayName: "Discord",    sendKey: .enter),
        AppProfile(bundleID: "com.tinyspeck.slackmacgap",     displayName: "Slack",      sendKey: .enter),
        AppProfile(bundleID: "com.facebook.archon",           displayName: "Messenger",  sendKey: .enter),
        AppProfile(bundleID: "net.whatsapp.WhatsApp",         displayName: "WhatsApp",   sendKey: .enter),
        AppProfile(bundleID: "com.microsoft.teams2",          displayName: "Teams",      sendKey: .enter),
        AppProfile(bundleID: "com.microsoft.teams",           displayName: "Teams",      sendKey: .enter),

        // Chat — Cmd+Enter to send
        AppProfile(bundleID: "com.electron.lark",             displayName: "Lark (飞书)", sendKey: .cmdEnter),
        AppProfile(bundleID: "com.bytedance.lark",            displayName: "Lark (飞书)", sendKey: .cmdEnter),
        AppProfile(bundleID: "com.alibaba.DingTalkMac",       displayName: "DingTalk (钉钉)", sendKey: .cmdEnter),

        // Productivity — auto-send off (user just wants transcription, not send)
        AppProfile(bundleID: "com.apple.Notes",               displayName: "Notes",      sendKey: .enter, autoSend: false),
        AppProfile(bundleID: "md.obsidian",                   displayName: "Obsidian",   sendKey: .enter, autoSend: false),
        AppProfile(bundleID: "notion.id",                     displayName: "Notion",     sendKey: .enter, autoSend: false),
        AppProfile(bundleID: "com.apple.dt.Xcode",            displayName: "Xcode",      sendKey: .enter, autoSend: false),
        AppProfile(bundleID: "com.microsoft.VSCode",          displayName: "VS Code",    sendKey: .enter, autoSend: false),
        AppProfile(bundleID: "com.apple.TextEdit",            displayName: "TextEdit",   sendKey: .enter, autoSend: false),
    ]
}

/// Persistent per-app profile store. Built-in defaults are seeded on first launch.
final class AppProfileStore {
    static let shared = AppProfileStore()

    private let defaultsKey = "appProfilesV1"
    private let seededKey = "appProfilesSeededV1"

    private var profiles: [String: AppProfile] = [:]
    private let lock = NSLock()

    private init() {
        load()
        seedBuiltInsIfNeeded()
    }

    // MARK: - Lookup

    /// Return the profile for the given bundle ID, or nil if none exists.
    func profile(for bundleID: String) -> AppProfile? {
        lock.lock(); defer { lock.unlock() }
        return profiles[bundleID]
    }

    /// All profiles, sorted by display name.
    func allProfiles() -> [AppProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.values.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    // MARK: - Mutation

    func upsert(_ profile: AppProfile) {
        lock.lock()
        profiles[profile.bundleID] = profile
        lock.unlock()
        save()
    }

    func remove(bundleID: String) {
        lock.lock()
        profiles.removeValue(forKey: bundleID)
        lock.unlock()
        save()
    }

    /// Reset to built-in defaults. Discards user customizations.
    func resetToDefaults() {
        lock.lock()
        profiles = [:]
        for p in BuiltInProfiles.all { profiles[p.bundleID] = p }
        lock.unlock()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            let list = try JSONDecoder().decode([AppProfile].self, from: data)
            profiles = Dictionary(uniqueKeysWithValues: list.map { ($0.bundleID, $0) })
        } catch {
            profileLog.error("Load failed: \(error, privacy: .public)")
        }
    }

    private func save() {
        lock.lock()
        let list = Array(profiles.values)
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(list)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            profileLog.error("Save failed: \(error, privacy: .public)")
        }
    }

    private func seedBuiltInsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        lock.lock()
        for p in BuiltInProfiles.all where profiles[p.bundleID] == nil {
            profiles[p.bundleID] = p
        }
        lock.unlock()
        save()
        UserDefaults.standard.set(true, forKey: seededKey)
        profileLog.info("Seeded \(BuiltInProfiles.all.count) built-in profiles")
    }
}

/// Helpers for querying the currently active app.
enum ActiveAppContext {
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static var frontmostDisplayName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
