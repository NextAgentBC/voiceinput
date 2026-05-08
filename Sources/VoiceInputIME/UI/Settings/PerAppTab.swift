import SwiftUI

struct PerAppTab: View {
    @State private var profiles: [AppProfile] = []
    @State private var runningApps: [(bundleID: String, name: String)] = []
    @State private var selectedProfileID: String?
    @State private var editingProfile: AppProfile?
    @State private var showAddSheet = false
    @State private var addBundleID = ""
    @State private var addDisplayName = ""
    @State private var addSendKey: SendKeyType = .enter
    @State private var addAutoSend = true
    @State private var addDelay: TimeInterval = 0.0
    @State private var addLLMModel = ""
    @State private var selectedAddID = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            profileList
            Divider()
            footer
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(profile: profile, onSave: { updated in
                AppProfileStore.shared.upsert(updated)
                reload()
            })
        }
        .sheet(isPresented: $showAddSheet) {
            AddProfileSheet(
                runningApps: runningApps.filter { app in !profiles.contains { $0.bundleID == app.bundleID } },
                onAdd: { profile in
                    AppProfileStore.shared.upsert(profile)
                    reload()
                }
            )
        }
        .onAppear {
            reload()
            loadRunningApps()
        }
    }

    private var toolbar: some View {
        HStack {
            Button(action: { showAddSheet = true }) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text("Per-app send key and auto-send overrides.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var profileList: some View {
        List(profiles, selection: $selectedProfileID) { profile in
            ProfileListRow(profile: profile)
                .tag(profile.bundleID)
                .onTapGesture { editingProfile = profile }
                .contextMenu {
                    Button("Edit") { editingProfile = profile }
                    Divider()
                    Button("Delete", role: .destructive) { deleteProfile(profile) }
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var footer: some View {
        HStack {
            Button("Reset to Defaults") {
                let confirmed = ConfirmAlert.destructive(
                    title: "Reset all per-app profiles to defaults?",
                    message: "This will remove your customizations and restore built-in defaults.",
                    confirmTitle: "Reset"
                )
                if confirmed {
                    AppProfileStore.shared.resetToDefaults()
                    reload()
                }
            }
            Spacer()
            Text("\(profiles.count) profiles")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func deleteProfile(_ profile: AppProfile) {
        let confirmed = ConfirmAlert.destructive(
            title: "Delete profile for \(profile.displayName)?",
            message: "This cannot be undone.",
            confirmTitle: "Delete"
        )
        if confirmed {
            AppProfileStore.shared.remove(bundleID: profile.bundleID)
            reload()
        }
    }

    private func reload() {
        profiles = AppProfileStore.shared.allProfiles()
    }

    private func loadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (id, name)
            }
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
    }
}

struct ProfileListRow: View {
    let profile: AppProfile

    private var summary: String {
        var parts: [String] = []
        parts.append("Auto-send: \(profile.autoSend ? "ON" : "OFF")")
        parts.append("Send key: \(profile.sendKey.displayName)")
        if let delay = profile.autoSendDelay {
            parts.append(String(format: "Delay: %.1fs", delay))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProfileEditorSheet: View {
    let profile: AppProfile
    let onSave: (AppProfile) -> Void

    @State private var sendKey: SendKeyType
    @State private var autoSend: Bool
    @State private var autoSendDelay: Double
    @State private var llmModelOverride: String
    @Environment(\.dismiss) private var dismiss

    init(profile: AppProfile, onSave: @escaping (AppProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _sendKey = State(initialValue: profile.sendKey)
        _autoSend = State(initialValue: profile.autoSend)
        _autoSendDelay = State(initialValue: profile.autoSendDelay ?? 0.0)
        _llmModelOverride = State(initialValue: profile.llmModelOverride ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Profile")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section {
                    LabeledContent("App") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(profile.displayName)
                                .font(.callout)
                            Text(profile.bundleID)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Auto Send", isOn: $autoSend)

                    Picker("Send Key", selection: $sendKey) {
                        ForEach(SendKeyType.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }

                    Stepper(
                        "Auto-send delay: \(String(format: "%.1f", autoSendDelay)) s",
                        value: $autoSendDelay,
                        in: 0.0...3.0,
                        step: 0.1
                    )
                }

                Section("LLM Override") {
                    TextField("Model (blank = global)", text: $llmModelOverride)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save") {
                    var updated = profile
                    updated.sendKey = sendKey
                    updated.autoSend = autoSend
                    updated.autoSendDelay = autoSendDelay > 0 ? autoSendDelay : nil
                    updated.llmModelOverride = llmModelOverride.isEmpty ? nil : llmModelOverride
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 420)
        .fixedSize()
    }
}

struct AddProfileSheet: View {
    let runningApps: [(bundleID: String, name: String)]
    let onAdd: (AppProfile) -> Void

    @State private var selectedID = ""
    @State private var manualBundleID = ""
    @State private var manualName = ""
    @State private var sendKey: SendKeyType = .enter
    @State private var autoSend = true
    @State private var autoSendDelay: Double = 0.0
    @State private var llmModelOverride = ""
    @State private var useManual = false
    @Environment(\.dismiss) private var dismiss

    private var effectiveBundleID: String { useManual ? manualBundleID : selectedID }
    private var effectiveName: String {
        if useManual { return manualName.isEmpty ? manualBundleID : manualName }
        return runningApps.first(where: { $0.bundleID == selectedID })?.name ?? selectedID
    }
    private var canAdd: Bool { !effectiveBundleID.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add App Profile")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section("App") {
                    if !runningApps.isEmpty {
                        Toggle("Enter manually", isOn: $useManual)
                    }
                    if useManual || runningApps.isEmpty {
                        TextField("Bundle ID (e.g. com.apple.TextEdit)", text: $manualBundleID)
                        TextField("Display name", text: $manualName)
                    } else {
                        Picker("Running app", selection: $selectedID) {
                            Text("Select…").tag("")
                            ForEach(runningApps, id: \.bundleID) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Auto Send", isOn: $autoSend)
                    Picker("Send Key", selection: $sendKey) {
                        ForEach(SendKeyType.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    Stepper(
                        "Auto-send delay: \(String(format: "%.1f", autoSendDelay)) s",
                        value: $autoSendDelay,
                        in: 0.0...3.0,
                        step: 0.1
                    )
                }

                Section("LLM Override") {
                    TextField("Model (blank = global)", text: $llmModelOverride)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Add") {
                    let profile = AppProfile(
                        bundleID: effectiveBundleID,
                        displayName: effectiveName,
                        sendKey: sendKey,
                        autoSend: autoSend,
                        autoSendDelay: autoSendDelay > 0 ? autoSendDelay : nil,
                        llmModelOverride: llmModelOverride.isEmpty ? nil : llmModelOverride
                    )
                    onAdd(profile)
                    dismiss()
                }
                .disabled(!canAdd)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 440)
        .fixedSize()
    }
}
