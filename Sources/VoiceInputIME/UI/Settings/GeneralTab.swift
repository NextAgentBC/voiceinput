import SwiftUI

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PermissionsSection()

                GroupBox(label: Label("Language", systemImage: "globe")) {
                    Picker("Recognition Language", selection: $settings.selectedLanguage) {
                        ForEach(AppSettings.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(8)
                }

                GroupBox(label: Label("Behavior", systemImage: "gear")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Auto Send after transcription", isOn: $settings.autoSend)
                        if settings.autoSend {
                            HStack {
                                Text("Send Key")
                                    .frame(width: 80, alignment: .trailing)
                                Picker("", selection: $settings.sendKey) {
                                    ForEach(SendKeyType.allCases, id: \.self) { key in
                                        Text(key.displayName).tag(key)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }
                            HStack {
                                Text("Delay")
                                    .frame(width: 80, alignment: .trailing)
                                Stepper(
                                    String(format: "%.1f s", settings.autoSendDelay),
                                    value: $settings.autoSendDelay,
                                    in: 0.0...3.0,
                                    step: 0.1
                                )
                            }
                            Text("While LLM is refining, press Esc or Cmd+. to cancel.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox(label: Label("How to Use", systemImage: "keyboard")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tap **Fn+Ctrl** to start recording, tap again to stop and transcribe.")
                        Text("While the LLM is refining: **Esc** or **Cmd+.** cancels (no paste).")
                        Text("If a cached result was wrong: menu → **Forget Last Correction**.")
                    }
                    .font(.caption)
                    .padding(8)
                }
            }
            .padding(20)
        }
    }
}
