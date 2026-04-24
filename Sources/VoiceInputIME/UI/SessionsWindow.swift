import Cocoa
import SwiftUI

final class SessionsWindowController {
    static let shared = SessionsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Voice Input — Sessions"
        w.contentView = NSHostingView(rootView: SessionsRootView())
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Root

struct SessionsRootView: View {
    @State private var sessions: [VSession] = []
    @State private var selectedID: String?
    @State private var searchQuery: String = ""
    @State private var searchResults: [(session: VSession, entry: TranscriptEntry)] = []

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)

            detail
                .frame(minWidth: 400)
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear { reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search transcripts…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(.thinMaterial)

            Divider()

            if !searchQuery.isEmpty && !searchResults.isEmpty {
                searchList
            } else {
                sessionList
            }

            Divider()
            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Text("\(sessions.count) sessions").font(.caption).foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private var sessionList: some View {
        List(selection: $selectedID) {
            ForEach(grouped(), id: \.0) { bucket in
                Section(header: Text(bucket.0).font(.caption).foregroundColor(.secondary)) {
                    ForEach(bucket.1, id: \.id) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    SessionStore.shared.deleteSession(session.id)
                                    reload()
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var searchList: some View {
        List(selection: $selectedID) {
            ForEach(searchResults, id: \.entry.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.entry.finalText)
                        .font(.callout)
                        .lineLimit(2)
                    HStack {
                        Text(item.session.appDisplayName ?? "Unknown")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(item.entry.timestamp.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .tag(item.session.id)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let session = sessions.first(where: { $0.id == id }) {
            SessionDetailView(session: session)
        } else {
            ContentUnavailableView("Select a session", systemImage: "text.bubble")
        }
    }

    // MARK: -

    private func reload() {
        sessions = SessionStore.shared.recentSessions(limit: 500)
    }

    private func runSearch() {
        guard !searchQuery.isEmpty else { searchResults = []; return }
        searchResults = SessionStore.shared.search(searchQuery, limit: 200)
    }

    private func grouped() -> [(String, [VSession])] {
        let cal = Calendar.current
        var map: [String: [VSession]] = [:]
        var order: [String] = []
        for s in sessions {
            let key = dateLabel(for: s.startedAt, cal: cal)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(s)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func dateLabel(for date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month().day())
    }
}

struct SessionRow: View {
    let session: VSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.appDisplayName ?? session.appBundleID ?? "Unknown")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Text("\(session.entryCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let summary = session.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text(session.startedAt.formatted(.dateTime.hour().minute()))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// Visual grouping: consecutive entries with identical final text become
/// one row with a "×N" badge.
struct EntryGroup: Identifiable {
    let id: String
    let entries: [TranscriptEntry]
    var representative: TranscriptEntry { entries.first! }
    var count: Int { entries.count }
    var firstTimestamp: Date { entries.first!.timestamp }
}

func collapseEntries(_ list: [TranscriptEntry]) -> [EntryGroup] {
    guard !list.isEmpty else { return [] }
    var groups: [EntryGroup] = []
    var buffer: [TranscriptEntry] = []
    var lastFinal: String?
    for e in list {
        if let last = lastFinal, last == e.finalText {
            buffer.append(e)
        } else {
            if !buffer.isEmpty {
                groups.append(EntryGroup(id: buffer.first!.id, entries: buffer))
            }
            buffer = [e]
            lastFinal = e.finalText
        }
    }
    if !buffer.isEmpty {
        groups.append(EntryGroup(id: buffer.first!.id, entries: buffer))
    }
    return groups
}

struct SessionDetailView: View {
    let session: VSession
    @State private var entries: [TranscriptEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.appDisplayName ?? "Unknown App")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button(action: exportMarkdown) {
                        Label("Export .md", systemImage: "square.and.arrow.up")
                    }
                }
                HStack(spacing: 16) {
                    Label(session.startedAt.formatted(.dateTime), systemImage: "clock")
                    Label("\(entries.count) entries", systemImage: "text.bubble")
                    if let bundle = session.appBundleID {
                        Text(bundle).font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if let summary = session.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                        .cornerRadius(6)
                }
            }
            .padding()
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(collapseEntries(entries)) { group in
                        EntryGroupRow(group: group)
                    }
                }
                .padding()
            }
        }
        .onAppear { reload() }
        .onChange(of: session.id) { _, _ in reload() }
    }

    private func reload() {
        entries = SessionStore.shared.entries(sessionID: session.id)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "session-\(session.startedAt.formatted(.iso8601)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var md = "# \(session.appDisplayName ?? "Session") — \(session.startedAt.formatted(.dateTime))\n\n"
        if let summary = session.summary { md += "> \(summary)\n\n" }
        for e in entries {
            md += "- **\(e.timestamp.formatted(.dateTime.hour().minute()))** \(e.finalText)\n"
            if e.rawText != e.finalText {
                md += "  - _raw:_ \(e.rawText)\n"
            }
        }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct EntryGroupRow: View {
    let group: EntryGroup

    var body: some View {
        let entry = group.representative
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(entry.finalText)
                    .font(.body)
                    .textSelection(.enabled)
                Spacer()
                if group.count > 1 {
                    Text("×\(group.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            // Show distinct raw variants when they differ from final.
            let rawVariants = Set(group.entries.map { $0.rawText }).filter { $0 != entry.finalText }
            if !rawVariants.isEmpty {
                ForEach(Array(rawVariants).prefix(3), id: \.self) { raw in
                    HStack(alignment: .top, spacing: 4) {
                        Text("raw:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(raw)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Text(group.firstTimestamp.formatted(.dateTime.hour().minute().second()))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(6)
    }
}
