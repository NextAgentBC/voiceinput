import Cocoa
import os.log

private let logger = Logger(subsystem: "com.voiceinput.app", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusBarIcon()
        statusItem.menu = buildMenu()

        let hotkey = GlobalHotkey.shared
        hotkey.onHotkeyDown = { RecordingSession.shared.startRecording() }
        hotkey.onHotkeyUp = { RecordingSession.shared.stopRecording() }
        hotkey.install()

        if !AppSettings.shared.isSTTConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        logger.info("Menu bar app started")
    }

    // MARK: - Status Bar Icon

    private func updateStatusBarIcon() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = AppSettings.shared

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let sessionsItem = NSMenuItem(title: "Sessions...", action: #selector(openSessions), keyEquivalent: "h")
        sessionsItem.target = self
        menu.addItem(sessionsItem)

        menu.addItem(.separator())

        let autoSendItem = NSMenuItem(title: "Auto Send", action: #selector(toggleAutoSend(_:)), keyEquivalent: "")
        autoSendItem.target = self
        autoSendItem.state = settings.autoSend ? .on : .off
        menu.addItem(autoSendItem)

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

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let enableItem = NSMenuItem(title: "Enable", action: #selector(toggleLLM(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(enableItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        let forgetItem = NSMenuItem(title: "Forget Last Correction", action: #selector(forgetLastCorrection), keyEquivalent: "")
        forgetItem.target = self
        forgetItem.toolTip = "If the last paste was wrong, click to un-learn that LLM cache entry."
        menu.addItem(forgetItem)

        let runAgentItem = NSMenuItem(title: "Run Learning Agent Now", action: #selector(runAgent), keyEquivalent: "")
        runAgentItem.target = self
        runAgentItem.toolTip = "Analyze recent sessions to mine new corrections + vocabulary."
        menu.addItem(runAgentItem)

        menu.addItem(.separator())

        let status = settings.isSTTConfigured ? "STT: Connected" : "STT: Not configured"
        let sttStatusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        sttStatusItem.isEnabled = false
        menu.addItem(sttStatusItem)

        menu.addItem(.separator())

        let howToItem = NSMenuItem(title: "Hold Fn to record", action: nil, keyEquivalent: "")
        howToItem.isEnabled = false
        menu.addItem(howToItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Voice Input", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc func menuWillOpen(_ menu: NSMenu) {
        statusItem.menu = buildMenu()
    }

    // MARK: - Actions

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func openSessions() {
        SessionsWindowController.shared.show()
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

    @objc func forgetLastCorrection() {
        RecordingSession.shared.rejectLastCacheKey()
    }

    @objc func runAgent() {
        LearningAgent.shared.runManualL2()
    }
}
