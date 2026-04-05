import Cocoa
import InputMethodKit

/// Thin IMKInputController subclass. Does NOT hold state.
/// All logic is delegated to InputSession (one per client).
class VoiceInputController: IMKInputController {

    // MARK: - Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }
        guard let client = sender as? (any IMKTextInput) else { return false }
        return InputSession.session(for: client).handleEvent(event, client: client)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        return Int(mask.rawValue)
    }

    // MARK: - Composition

    override func composedString(_ sender: Any!) -> Any! {
        guard let client = sender as? (any IMKTextInput) else { return "" }
        return InputSession.session(for: client).composedString()
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? (any IMKTextInput) else { return }
        InputSession.session(for: client).commitComposition(client: client)
    }

    override func cancelComposition() {
        if let client = self.client() {
            InputSession.session(for: client).cancelComposition(client: client)
        }
    }

    // MARK: - Menu (actions handled by this controller)

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let settings = AppSettings.shared

        // Auto Send
        let autoSendItem = NSMenuItem(title: "Auto Send (Enter)", action: #selector(menuToggleAutoSend(_:)), keyEquivalent: "")
        autoSendItem.target = self
        autoSendItem.state = settings.autoSend ? .on : .off
        menu.addItem(autoSendItem)

        menu.addItem(.separator())

        // LLM
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let enableItem = NSMenuItem(title: "Enable", action: #selector(menuToggleLLM(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(enableItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // Dictionary
        let dictItem = NSMenuItem(title: "Edit Dictionary...", action: #selector(menuEditDictionary(_:)), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        // Vocabulary stats
        let vocabCount = VocabularyDB.shared.totalCount()
        let vocabItem = NSMenuItem(title: "Vocabulary: \(vocabCount) entries", action: nil, keyEquivalent: "")
        vocabItem.isEnabled = false
        menu.addItem(vocabItem)

        return menu
    }

    // MARK: - Menu Actions

@objc func menuToggleAutoSend(_ sender: NSMenuItem) {
        AppSettings.shared.autoSend = !AppSettings.shared.autoSend
    }

@objc func menuToggleLLM(_ sender: NSMenuItem) {
        AppSettings.shared.llmEnabled = !AppSettings.shared.llmEnabled
    }

    @objc func menuEditDictionary(_ sender: NSMenuItem) {
        let dictPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput/dictionary.json")
        NSWorkspace.shared.open(dictPath)
    }
}
