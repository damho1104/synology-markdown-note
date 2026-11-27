import SwiftUI
import NoteCore

struct GlobalSearchSheet: View {
    let library: LibraryStore
    let onSelect: (UUID) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var result: SearchResult?
    @FocusState private var searchFocused: Bool

    private struct SearchResult {
        let request: GlobalNoteSearchRequest
        let notes: [NoteSummary]
        var error: String?
    }

    private var request: GlobalNoteSearchRequest {
        GlobalNoteSearchRequest(query: query, library: library)
    }
    private var currentResult: SearchResult? { result?.request == request ? result : nil }
    private var rows: [NoteSummary] { currentResult?.notes ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(appText("Search All Notes"), systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(appText("Close Search"))
                    .keyboardShortcut(.cancelAction)
            }
            TextField(appText("Search titles, previews, tags, and note bodies"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel(appText("Search All Notes"))
                .accessibilityIdentifier("global-search-query")
                // Native TextField submission respects the input method's
                // marked text; do not intercept Return with a key handler.
                .onSubmit { if let first = rows.first { onSelect(first.id) } }
            Text(appText("Search titles, previews, tags, and downloaded note bodies across all notes outside the Trash."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if currentResult == nil {
                    ProgressView().controlSize(.small)
                    Text(appText("Searching…"))
                } else {
                    Text(appText("Results: %@", AppLocalization.number(rows.count)) + (rows.count > 100 ? appText(" · Showing the first 100") : ""))
                }
                Spacer()
                Text(appText("Return to Open First Result · Esc to Close"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("global-search-status")
            Divider()
            if let error = currentResult?.error {
                ContentUnavailableView(appText("Search Failed"), systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if currentResult != nil && rows.isEmpty {
                ContentUnavailableView(appText("No Search Results"), systemImage: "magnifyingglass",
                                       description: Text(appText("Try a different search term.")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows.prefix(100)) { note in
                            Button { onSelect(note.id) } label: { resultRow(note) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("global-search-result-\(note.id)")
                        }
                    }
                }
                .accessibilityLabel(appText("Global Search Results"))
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear { searchFocused = true }
        .task(id: request) {
            let request = request
            do {
                if !request.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                let notes = try await library.globalSearch(query: request.query)
                try Task.checkCancellation()
                guard request == self.request else { return }
                result = SearchResult(request: request, notes: notes)
            } catch is CancellationError {
                // A changed query, dismissed sheet or account switch owns the UI now.
            } catch {
                guard !Task.isCancelled, request == self.request else { return }
                result = SearchResult(request: request, notes: [], error: error.localizedDescription)
            }
        }
    }

    private func resultRow(_ note: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.title.isEmpty ? appText("Untitled") : note.title).fontWeight(.medium).lineLimit(1)
            Text(notebookName(note) + (note.tags.isEmpty ? "" : " · " + note.tags.map { "#" + $0 }.joined(separator: " ")))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !note.excerpt.isEmpty {
                Text(note.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func notebookName(_ note: NoteSummary) -> String {
        library.notebooks.first(where: { $0.id == note.notebookID })?.name ?? appText("Unknown Notebook")
    }
}
