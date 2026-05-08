import SwiftUI

/// Combined "Tools" tab — per-app profiles, vocabulary editor, history /
/// learning agent / LLM cache. Each section folds into a DisclosureGroup so
/// the tab opens compact and the user expands only what they need.
struct ToolsTab: View {
    @State private var perAppOpen = false
    @State private var vocabOpen = false
    @State private var historyOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                DisclosureGroup(isExpanded: $perAppOpen) {
                    PerAppTab()
                        .frame(minHeight: 200)
                } label: {
                    Label("Per-app profiles", systemImage: "app.badge")
                        .font(.headline)
                }

                DisclosureGroup(isExpanded: $vocabOpen) {
                    VocabTab()
                        .frame(minHeight: 240)
                } label: {
                    Label("Vocabulary", systemImage: "text.book.closed")
                        .font(.headline)
                }

                DisclosureGroup(isExpanded: $historyOpen) {
                    HistoryTab()
                        .frame(minHeight: 280)
                } label: {
                    Label("History · Cache · Learning", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                }
            }
            .padding(20)
        }
    }
}
