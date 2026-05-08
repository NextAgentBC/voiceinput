import SwiftUI

struct HistoryTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SessionLoggingSection()
                LearningAgentSection()
                LLMCacheSection()
            }
            .padding(20)
        }
    }
}

// MARK: - LLM Cache Inspector

struct LLMCacheSection: View {
    @State private var cacheStats: LLMCache.CacheStats = LLMCache.CacheStats(totalEntries: 0, totalBytes: 0, totalHits: 0, lastHitAge: nil)
    @State private var topRows: [LLMCache.CacheRow] = []
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(
                isExpanded: $isExpanded,
                content: {
                    VStack(alignment: .leading, spacing: 12) {
                        statsLine
                        if !topRows.isEmpty {
                            topRowsTable
                        }
                        actionButtons
                    }
                    .padding(.top, 8)
                },
                label: {
                    Label("LLM Cache", systemImage: "memorychip")
                        .font(.headline)
                }
            )
            .padding(8)
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { refresh() }
        }
    }

    private var statsLine: some View {
        let kb = cacheStats.totalBytes / 1024
        var parts: [String] = ["\(cacheStats.totalEntries) entries", "\(kb) KB", "\(cacheStats.totalHits) hits"]
        if let age = cacheStats.lastHitAge {
            let s = Int(age)
            let ago: String
            if s < 60 { ago = "\(s)s ago" }
            else if s < 3600 { ago = "\(s/60)m ago" }
            else if s < 86400 { ago = "\(s/3600)h ago" }
            else { ago = "\(s/86400)d ago" }
            parts.append("last hit \(ago)")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var topRowsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top 10 by hits")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Raw").frame(maxWidth: .infinity, alignment: .leading).font(.caption2).foregroundColor(.secondary)
                    Text("Refined").frame(maxWidth: .infinity, alignment: .leading).font(.caption2).foregroundColor(.secondary)
                    Text("Hits").frame(width: 50, alignment: .trailing).font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))

                ForEach(topRows) { row in
                    HStack(spacing: 0) {
                        Text(row.raw)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Text(row.refined)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Text("\(row.hits)")
                            .frame(width: 50, alignment: .trailing)
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    Divider()
                }
            }
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Clear All Cache") {
                let confirmed = ConfirmAlert.destructive(
                    title: "Clear entire LLM cache?",
                    message: "All \(cacheStats.totalEntries) cached refinements will be deleted. The next transcription will re-query the LLM.",
                    confirmTitle: "Clear All"
                )
                if confirmed {
                    LLMCache.shared.clear()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { refresh() }
                }
            }
            .foregroundColor(.red)

            Button("Delete Poisoned") {
                let confirmed = ConfirmAlert.destructive(
                    title: "Delete poisoned cache entries?",
                    message: "Removes entries with newlines, excessive length, or suspicious expansion ratios.",
                    confirmTitle: "Delete"
                )
                if confirmed {
                    let deleted = LLMCache.shared.deletePoisoned()
                    _ = deleted
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { refresh() }
                }
            }

            Button("Refresh") { refresh() }
                .buttonStyle(.borderless)
        }
    }

    private func refresh() {
        cacheStats = LLMCache.shared.stats()
        topRows = LLMCache.shared.topRows(limit: 10)
    }
}
