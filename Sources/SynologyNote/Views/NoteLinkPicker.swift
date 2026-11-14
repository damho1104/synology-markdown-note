import SwiftUI
import NoteCore

/// Shared search, notebook filtering and target selection for editor, [[ and inspector.
@MainActor @Observable final class NoteLinkPickerModel {
    let candidates: [NoteSummary]
    let notebooks: [Notebook]
    var query = ""
    var notebookID: String? = nil
    var selected = 0

    init(candidates: [NoteSummary], notebooks: [Notebook], query: String = "") {
        self.candidates = candidates.filter { !$0.isTrashed && $0.mode != .locked }
        self.notebooks = notebooks
        self.query = query
    }

    var results: [NoteSummary] {
        candidates.filter { note in
            (notebookID == nil || note.notebookID == notebookID) &&
            (query.isEmpty || note.title.localizedStandardContains(query))
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    func step(_ delta: Int) {
        let count = results.count
        if count > 0 { selected = ((min(selected, count - 1) + delta) % count + count) % count }
    }
    var chosen: NoteSummary? {
        let rows = results
        return rows.isEmpty ? nil : rows[min(selected, rows.count - 1)]
    }
    func title(_ note: NoteSummary) -> String { note.title.isEmpty ? "제목 없음" : note.title }
    func notebook(_ note: NoteSummary) -> String {
        notebooks.first(where: { $0.id == note.notebookID })?.name ?? "알 수 없는 메모장"
    }
}

struct NoteLinkPicker: View {
    @Bindable var model: NoteLinkPickerModel
    var searchField: Bool = true
    var onSelect: (NoteSummary) -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if searchField {
                TextField("노트 제목 검색", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityIdentifier("note-link-search")
                    .onChange(of: model.query) { _, _ in model.selected = 0 }
                    .onKeyPress(.upArrow) { model.step(-1); return .handled }
                    .onKeyPress(.downArrow) { model.step(1); return .handled }
                Picker("메모장", selection: $model.notebookID) {
                    Text("전체 메모장").tag(String?.none)
                    ForEach(model.notebooks) { notebook in
                        Text(notebook.name.isEmpty ? "이름 없는 메모장" : notebook.name).tag(Optional(notebook.id))
                    }
                }
                .accessibilityIdentifier("note-link-notebook")
                .onChange(of: model.notebookID) { _, _ in model.selected = 0 }
                Text("↑↓ 선택 · Enter 연결 · Esc 취소").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, note in
                            Button {
                                model.selected = index
                                onSelect(note)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(model.title(note)).fontWeight(.medium).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(model.notebook(note)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Text(note.excerpt.isEmpty ? "본문 미리보기 없음" : note.excerpt)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == model.selected ? Color.accentColor.opacity(0.17) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(note.id)
                            .accessibilityIdentifier("note-link-result-\(index)")
                        }
                    }
                }
                .onChange(of: model.selected) { _, _ in if let chosen = model.chosen { proxy.scrollTo(chosen.id) } }
            }
            if model.results.isEmpty { Text("일치하는 노트 없음").foregroundStyle(.secondary).font(.caption) }
            if searchField {
                HStack { Spacer(); Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                    Button("연결") { if let chosen = model.chosen { onSelect(chosen) } }
                        .disabled(model.chosen == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(searchField ? 14 : 12)
        .frame(minWidth: searchField ? 450 : 0, idealWidth: searchField ? 520 : 300,
               maxWidth: searchField ? nil : .infinity,
               minHeight: searchField ? 360 : 0, idealHeight: searchField ? 490 : 280,
               maxHeight: searchField ? nil : .infinity)
        .background {
            if !searchField {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
        }
        .overlay {
            if !searchField {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .shadow(color: searchField ? .clear : .black.opacity(0.22), radius: searchField ? 0 : 6, y: 3)
        .padding(searchField ? 0 : 6)
        .onMoveCommand { direction in
            switch direction { case .up: model.step(-1); case .down: model.step(1); default: break }
        }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onKeyPress(.return) {
            if let chosen = model.chosen { onSelect(chosen) }
            return .handled
        }
        .onAppear { if searchField { focused = true } }
    }
}

/// Own the observable picker state for the entire presentation. A parent view
/// refresh (for example, while background sync updates summaries) must not
/// reset the user's query, notebook filter or highlighted result.
struct NoteLinkPickerSheet: View {
    @State private var model: NoteLinkPickerModel
    let onSelect: (NoteSummary) -> Void
    let onCancel: () -> Void

    init(candidates: [NoteSummary], notebooks: [Notebook],
         onSelect: @escaping (NoteSummary) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: NoteLinkPickerModel(candidates: candidates, notebooks: notebooks))
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        NoteLinkPicker(model: model, onSelect: onSelect, onCancel: onCancel)
    }
}
