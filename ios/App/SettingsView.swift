import SwiftUI

/// User-facing settings stored in the App Group so the keyboard extension sees changes live.
struct SettingsView: View {
    @State private var engine: String = SharedSettings.engine
    @State private var language: String = SharedSettings.language
    @State private var cloudURL: String = SharedSettings.cloudURL
    @State private var cloudAPIKey: String = SharedSettings.cloudAPIKey
    @State private var autoInsertSpace: Bool = SharedSettings.autoInsertSpace

    private let engines = [("apple", "Apple (Local)"), ("cloud", "Cloud API")]
    private let languages = [
        ("zh-CN", "中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $engine) {
                    ForEach(engines, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: engine) { _, v in SharedSettings.engine = v }
            }

            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: language) { _, v in SharedSettings.language = v }
            }

            if engine == "cloud" {
                Section("Cloud API") {
                    TextField("Endpoint URL", text: $cloudURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: cloudURL) { _, v in SharedSettings.cloudURL = v }
                    SecureField("API Key", text: $cloudAPIKey)
                        .onChange(of: cloudAPIKey) { _, v in SharedSettings.cloudAPIKey = v }
                }
            }

            Section("Behavior") {
                Toggle("Insert space after text", isOn: $autoInsertSpace)
                    .onChange(of: autoInsertSpace) { _, v in SharedSettings.autoInsertSpace = v }
            }
        }
        .navigationTitle("Settings")
    }
}
