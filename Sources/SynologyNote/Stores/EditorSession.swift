import Foundation
import Observation
import NoteCore

@MainActor @Observable
final class EditorSession: Identifiable {
    var note: NoteRecord
    var isSaving = false
    var isDownloading = false
    var saveError: String?
    var editGeneration = 0
    var savedGeneration = 0
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var downloadTask: Task<Void, Never>?
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let workspaceGeneration: Int
    nonisolated let id: UUID
    var localStatus: String { saveError != nil ? "기기 저장 실패" : isSaving || editGeneration != savedGeneration ? "저장 중…" : "기기 저장됨" }
    init(note: NoteRecord, workspaceGeneration: Int = 0) {
        self.note = note
        self.id = note.id
        self.workspaceGeneration = workspaceGeneration
    }
}

enum EditorMode: String, CaseIterable {
    case source, split, read
    var title: String {
        switch self { case .source: return "원문"; case .split: return "분할"; case .read: return "읽기" }
    }
}

enum LibraryFilter: Hashable {
    case all, favorites, notebook(String), stack(String), tag(String), smart(UUID), trash, graph
    var title: String {
        switch self {
        case .all: return "전체 노트"
        case .favorites: return "즐겨찾기"
        case .notebook: return "노트북"
        case .stack(let name): return name
        case .tag(let name): return "#" + name
        case .smart: return "스마트 메모장"
        case .trash: return "휴지통"
        case .graph: return "전체 그래프"
        }
    }
}
