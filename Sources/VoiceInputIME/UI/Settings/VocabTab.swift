import SwiftUI

struct VocabEntry: Identifiable {
    let id: String
    let original: String
    let corrected: String
    let frequency: Int
    let source: String
}

struct VocabTab: View {
    @State private var entries: [VocabEntry] = []
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\VocabEntry.frequency, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var showAddSheet = false

    private var filtered: [VocabEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.original.lowercased().contains(q) || $0.corrected.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Original", value: \.original)
                TableColumn("Corrected", value: \.corrected)
                TableColumn("Frequency") { entry in
                    Text("\(entry.frequency)")
                }
                .width(80)
                TableColumn("Source", value: \.source)
                    .width(80)
            }
            .onChange(of: sortOrder) { _, newOrder in
                entries.sort(using: newOrder)
            }

            Divider()
            footer
        }
        .sheet(isPresented: $showAddSheet) {
            AddVocabSheet { original, corrected in
                VocabularyDB.shared.learn(original: original, corrected: corrected, source: "user", confidence: 1.0)
                reload()
            }
        }
        .onAppear { reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search vocabulary…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Divider().frame(height: 20)
            Button(action: { showAddSheet = true }) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Button("Delete Selected") {
                deleteSelected()
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)

            Button("Reset Auto-learned") {
                resetAutoLearned()
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("\(entries.count) entries")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func reload() {
        let raw = VocabularyDB.shared.allEntries()
        entries = raw.map { VocabEntry(id: "\($0.original)|\($0.corrected)", original: $0.original, corrected: $0.corrected, frequency: $0.frequency, source: $0.source) }
        entries.sort(using: sortOrder)
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        let confirmed = ConfirmAlert.destructive(
            title: "Delete \(selection.count) \(selection.count == 1 ? "entry" : "entries")?",
            message: "This cannot be undone.",
            confirmTitle: "Delete"
        )
        guard confirmed else { return }
        for id in selection {
            if let entry = entries.first(where: { $0.id == id }) {
                VocabularyDB.shared.delete(original: entry.original, corrected: entry.corrected)
            }
        }
        selection = []
        reload()
    }

    private func resetAutoLearned() {
        let autoCount = entries.filter { $0.source != "user" }.count
        let confirmed = ConfirmAlert.destructive(
            title: "Delete \(autoCount) auto-learned entries?",
            message: "Entries with source 'user' are kept. This cannot be undone.",
            confirmTitle: "Reset"
        )
        guard confirmed else { return }
        for entry in entries where entry.source != "user" {
            VocabularyDB.shared.delete(original: entry.original, corrected: entry.corrected)
        }
        reload()
    }
}

struct AddVocabSheet: View {
    let onAdd: (String, String) -> Void

    @State private var original = ""
    @State private var corrected = ""
    @Environment(\.dismiss) private var dismiss

    private var canAdd: Bool {
        let o = original.trimmingCharacters(in: .whitespaces)
        let c = corrected.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !c.isEmpty, o != c else { return false }
        guard o.count >= 2 else { return false }
        let isASCII = o.allSatisfy { $0.isASCII }
        if isASCII && o.count < 4 { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Vocabulary Entry")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section {
                    TextField("Original (what STT produces)", text: $original)
                    TextField("Corrected (what you want)", text: $corrected)
                }
                .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            .padding(.bottom, 4)

            if !original.isEmpty && !canAdd {
                Text("Original must be ≥2 chars (ASCII ≥4), differ from corrected, and corrected must not be empty.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Add") {
                    onAdd(
                        original.trimmingCharacters(in: .whitespaces),
                        corrected.trimmingCharacters(in: .whitespaces)
                    )
                    dismiss()
                }
                .disabled(!canAdd)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 380)
        .fixedSize()
    }
}
