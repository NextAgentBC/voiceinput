import SwiftUI

@main
struct VoiceInputApp: App {

    @State private var showingRecording = false
    @State private var recordingRequestID: UUID = UUID()
    @State private var recordingLanguage: String = "zh-CN"
    @State private var showMalformedAlert = false

    init() {
        SharedSettings.shared.load()
#if DEBUG
        AppGroupBridge.selfTest()
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $showingRecording) {
                    RecordingView(requestID: recordingRequestID, language: recordingLanguage)
                }
                .alert("Invalid recording request", isPresented: $showMalformedAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("The URL could not be parsed as a valid recording request.")
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
    }

    // MARK: - URL Handling

    /// Parses `voiceinput://record?lang=<code>&id=<uuid>&host=<bundleID>`
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "voiceinput",
              url.host == "record",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            showMalformedAlert = true
            return
        }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        guard let idString = params["id"], let parsedID = UUID(uuidString: idString) else {
            showMalformedAlert = true
            return
        }

        let lang = params["lang"] ?? "zh-CN"
        let host = params["host"]

        // Clear stale result from any previous run
        AppGroupBridge.clearResult()

        // Write the new request
        let req = AppGroupBridge.RecordRequest(
            id: parsedID,
            createdAt: Date(),
            language: lang,
            hostBundleID: host
        )
        AppGroupBridge.writeRequest(req)
        AppGroupBridge.post(AppGroupBridge.didStartRequestNotification)

        // Update state and show the recording modal
        recordingRequestID = parsedID
        recordingLanguage = lang
        showingRecording = true
    }
}
