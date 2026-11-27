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
    var localStatus: String { saveError != nil ? appText("Local Save Failed") : isSaving || editGeneration != savedGeneration ? appText("Saving…") : appText("Saved on This Mac") }
    init(note: NoteRecord, workspaceGeneration: Int = 0) {
        self.note = note
        self.id = note.id
        self.workspaceGeneration = workspaceGeneration
    }
}

enum EditorMode: String, CaseIterable {
    case source, split, read
    var title: String {
        switch self { case .source: return appText("Source"); case .split: return appText("Split"); case .read: return appText("Reading") }
    }
}

enum LibraryFilter: Hashable {
    case all, favorites, notebook(String), stack(String), tag(String), smart(UUID), trash, graph
    var title: String {
        switch self {
        case .all: return appText("All Notes")
        case .favorites: return appText("Favorites")
        case .notebook: return appText("Notebook")
        case .stack(let name): return name
        case .tag(let name): return "#" + name
        case .smart: return appText("Smart Notebook")
        case .trash: return appText("Trash")
        case .graph: return appText("Note Graph")
        }
    }
}
