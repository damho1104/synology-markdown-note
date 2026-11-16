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
                Label("전체 노트 검색", systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("검색 닫기")
                    .keyboardShortcut(.cancelAction)
            }
            TextField("노트 제목·미리보기·태그·본문 검색", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("전체 노트 검색어")
                .accessibilityIdentifier("global-search-query")
                // Native TextField submission respects the input method's
                // marked text; do not intercept Return with a key handler.
                .onSubmit { if let first = rows.first { onSelect(first.id) } }
            Text("휴지통을 제외한 모든 노트의 제목·미리보기·태그와 내려받은 본문을 검색합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if currentResult == nil {
                    ProgressView().controlSize(.small)
                    Text("검색 중…")
                } else {
                    Text("검색 결과 \(rows.count)개" + (rows.count > 100 ? " · 처음 100개 표시" : ""))
                }
                Spacer()
                Text("Enter 첫 결과 열기 · Esc 닫기")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("global-search-status")
            Divider()
            if let error = currentResult?.error {
                ContentUnavailableView("검색하지 못했습니다", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if currentResult != nil && rows.isEmpty {
                ContentUnavailableView("검색 결과가 없습니다", systemImage: "magnifyingglass",
                                       description: Text("다른 검색어를 입력해 보세요."))
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
                .accessibilityLabel("전체 검색 결과")
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
            Text(note.title.isEmpty ? "제목 없음" : note.title).fontWeight(.medium).lineLimit(1)
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
        library.notebooks.first(where: { $0.id == note.notebookID })?.name ?? "알 수 없는 메모장"
    }
}
