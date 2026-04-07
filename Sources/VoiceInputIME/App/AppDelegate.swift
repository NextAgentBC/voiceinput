import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true  // Adapts to light/dark mode
        }
        statusItem.menu = buildMenu()

        // Install global Fn key monitor
        let hotkey = GlobalHotkey.shared
        hotkey.onHotkeyDown = { RecordingSession.shared.startRecording() }
        hotkey.onHotkeyUp = { RecordingSession.shared.stopRecording() }
        hotkey.install()

        // Show settings on first run
        if !AppSettings.shared.isSTTConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        NSLog("[VoiceInput] Menu bar app started")
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = AppSettings.shared

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Auto Send
        let autoSendItem = NSMenuItem(title: "Auto Send (Enter)", action: #selector(toggleAutoSend(_:)), keyEquivalent: "")
        autoSendItem.target = self
        autoSendItem.state = settings.autoSend ? .on : .off
        menu.addItem(autoSendItem)

        // Language
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in AppSettings.supportedLanguages {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = settings.selectedLanguage == lang.code ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // LLM
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let enableItem = NSMenuItem(title: "Enable", action: #selector(toggleLLM(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(enableItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // Edit Dictionary
        let dictItem = NSMenuItem(title: "Edit Dictionary...", action: #selector(editDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        // Status
        let status = settings.isSTTConfigured ? "STT: Connected" : "STT: Not configured"
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // How to use
        let howToItem = NSMenuItem(title: "Hold Fn to record", action: nil, keyEquivalent: "")
        howToItem.isEnabled = false
        menu.addItem(howToItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Voice Input", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu needs refresh on each open

    @objc func menuWillOpen(_ menu: NSMenu) {
        statusItem.menu = buildMenu()
    }

    // MARK: - Actions

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func toggleAutoSend(_ sender: NSMenuItem) {
        AppSettings.shared.autoSend.toggle()
        statusItem.menu = buildMenu()
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        AppSettings.shared.selectedLanguage = code
        statusItem.menu = buildMenu()
    }

    @objc func toggleLLM(_ sender: NSMenuItem) {
        AppSettings.shared.llmEnabled.toggle()
        statusItem.menu = buildMenu()
    }

    @objc func editDictionary() {
        let dictPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput/dictionary.json")
        NSWorkspace.shared.open(dictPath)
    }
}
