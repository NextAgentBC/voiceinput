import Cocoa
import os.log

private let logger = Logger(subsystem: "com.voiceinput.app", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastSTTErrorDate: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = buildMenu()

        // Toggle-mode hotkey: tap once to start recording, tap again to stop.
        // Hold-to-talk (the original behaviour) was awkward with the Fn+Ctrl
        // combo and caused fatigue for long utterances. We ignore the up
        // transition and only act on each fresh press.
        let hotkey = GlobalHotkey.shared
        hotkey.onHotkeyDown = {
            let rec = RecordingSession.shared
            if rec.isRecording {
                rec.stopRecording()
            } else {
                rec.startRecording()
            }
        }
        hotkey.onHotkeyUp = { /* no-op in toggle mode */ }
        hotkey.install()

        requestPermissionsIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSTTError(_:)),
            name: .voiceInputSTTError,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .voiceInputStateChanged,
            object: nil
        )

        refreshStatusBarIcon()

        // If audio capture was on at last quit, resume on launch.
        let s = AppSettings.shared
        if s.audioCaptureEnabled, !s.audioCaptureFolderPath.isEmpty {
            do {
                try MeetingTranscriber.shared.start(folder: URL(fileURLWithPath: s.audioCaptureFolderPath))
            } catch {
                logger.error("Audio capture auto-start failed: \(error.localizedDescription, privacy: .public)")
                s.audioCaptureEnabled = false
            }
        }

        if !AppSettings.shared.isSTTConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

        logger.info("Menu bar app started")
    }

    // MARK: - Permissions

    private var permissionAlertShown = false

    private func requestPermissionsIfNeeded() {
        let micStatus = PermissionsManager.microphoneStatus()
        let speechStatus = PermissionsManager.speechRecognitionStatus()

        let group = DispatchGroup()
        var micDenied = false
        var speechDenied = false

        if micStatus == .undetermined {
            group.enter()
            PermissionsManager.requestMicrophone { granted in
                micDenied = !granted
                group.leave()
            }
        } else {
            micDenied = (micStatus == .denied)
        }

        if speechStatus == .undetermined {
            group.enter()
            PermissionsManager.requestSpeechRecognition { granted in
                speechDenied = !granted
                group.leave()
            }
        } else {
            speechDenied = (speechStatus == .denied)
        }

        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshStatusBarIcon()
                guard !self!.permissionAlertShown else { return }
                if micDenied || speechDenied {
                    self?.permissionAlertShown = true
                    self?.showPermissionDeniedAlert(mic: micDenied, speech: speechDenied)
                }
            }
        }
    }

    private func showPermissionDeniedAlert(mic: Bool, speech: Bool) {
        let alert = NSAlert()
        alert.messageText = "Voice Input needs permission to work"
        if mic && speech {
            alert.informativeText = "Voice Input needs Microphone and Speech Recognition access to record and transcribe your voice."
        } else if mic {
            alert.informativeText = "Voice Input needs Microphone access to record."
        } else {
            alert.informativeText = "Voice Input needs Speech Recognition access to transcribe."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            PermissionsManager.openSystemSettings(for: mic ? .microphone : .speechRecognition)
        }
    }

    // MARK: - Status Bar Icon

    @objc private func handleSTTError(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastSTTErrorDate = Date()
            refreshStatusBarIcon()
        }
        // Clear the warning icon after 60s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.refreshStatusBarIcon() }
        }
    }

    @objc private func handleStateChanged() {
        MainActor.assumeIsolated { refreshStatusBarIcon() }
    }

    @MainActor func refreshStatusBarIcon() {
        guard let button = statusItem.button else { return }

        let micStatus = PermissionsManager.microphoneStatus()
        let axStatus = PermissionsManager.accessibilityStatus()

        if micStatus == .denied || axStatus == .denied {
            button.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Voice Input — permission denied")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            return
        }

        let recentError = lastSTTErrorDate.map { Date().timeIntervalSince($0) < 60 } ?? false
        let notConfigured = !AppSettings.shared.isSTTConfigured

        if notConfigured || recentError {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Voice Input — configuration issue")
            button.image?.isTemplate = false
            button.contentTintColor = .systemYellow
            return
        }

        let session = RecordingSession.shared
        if session.isRecording || session.isRefining {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input — recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
            return
        }

        // Idle, all good — plain template icon.
        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice Input")
        button.image?.isTemplate = true
        button.contentTintColor = nil
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = AppSettings.shared

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let sessionsItem = NSMenuItem(title: "Sessions...", action: #selector(openSessions), keyEquivalent: "")
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

        // Meeting Notes — continuous background transcription appended to one
        // Markdown file per session (started fresh on each enable).
        let audioItem = NSMenuItem(title: "Meeting Notes (auto-transcribe)", action: #selector(toggleAudioCapture(_:)), keyEquivalent: "")
        audioItem.target = self
        audioItem.state = settings.audioCaptureEnabled ? .on : .off
        audioItem.toolTip = "When enabled, continuously transcribes audio and appends to a single .md file per session."
        menu.addItem(audioItem)

        let folderTitle: String = {
            let path = settings.audioCaptureFolderPath
            if path.isEmpty { return "Notes Folder: (not set)" }
            return "Notes Folder: \((path as NSString).abbreviatingWithTildeInPath)"
        }()
        let folderItem = NSMenuItem(title: folderTitle, action: #selector(chooseAudioFolder), keyEquivalent: "")
        folderItem.target = self
        folderItem.toolTip = "Click to choose where meeting-notes Markdown files are saved."
        menu.addItem(folderItem)

        menu.addItem(.separator())

        let status = settings.isSTTConfigured ? "STT: Connected" : "STT: Not configured"
        let sttStatusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        sttStatusItem.isEnabled = false
        menu.addItem(sttStatusItem)

        menu.addItem(.separator())

        let howToItem = NSMenuItem(title: "Tap Fn+Ctrl to start, tap again to stop", action: nil, keyEquivalent: "")
        howToItem.isEnabled = false
        menu.addItem(howToItem)

        let cancelHintItem = NSMenuItem(title: "Esc / Cmd+. cancels during refining", action: nil, keyEquivalent: "")
        cancelHintItem.isEnabled = false
        menu.addItem(cancelHintItem)

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
        MainActor.assumeIsolated { RecordingSession.shared.rejectLastCacheKey() }
    }

    @objc func runAgent() {
        LearningAgent.shared.runManualL2()
    }

    // MARK: - Audio capture

    @objc func toggleAudioCapture(_ sender: NSMenuItem) {
        let s = AppSettings.shared
        if s.audioCaptureEnabled {
            // Was on → turn off.
            MeetingTranscriber.shared.stop()
            s.audioCaptureEnabled = false
        } else {
            // Need a folder before we can start. Prompt if missing.
            if s.audioCaptureFolderPath.isEmpty {
                chooseAudioFolder()
                if s.audioCaptureFolderPath.isEmpty {
                    statusItem.menu = buildMenu()
                    return
                }
            }
            let url = URL(fileURLWithPath: s.audioCaptureFolderPath)
            do {
                try MeetingTranscriber.shared.start(folder: url)
                s.audioCaptureEnabled = true
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not start audio recording"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                s.audioCaptureEnabled = false
            }
        }
        statusItem.menu = buildMenu()
    }

    @objc func chooseAudioFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select a folder for rolling audio files"
        if let existing = AppSettings.shared.audioCaptureFolderPath as String?,
           !existing.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: existing)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.audioCaptureFolderPath = url.path
        // If recording was already on, restart with new folder.
        if AppSettings.shared.audioCaptureEnabled {
            MeetingTranscriber.shared.stop()
            do {
                try MeetingTranscriber.shared.start(folder: url)
            } catch {
                AppSettings.shared.audioCaptureEnabled = false
            }
        }
        statusItem.menu = buildMenu()
    }
}
