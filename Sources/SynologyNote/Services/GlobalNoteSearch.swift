import Foundation
import NoteCore

@MainActor struct GlobalNoteSearchRequest: Equatable {
    let query: String
    let accountGeneration: Int
    let searchIndexRevision: Int
    let summaries: [NoteSummary]

    init(query: String, library: LibraryStore) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        accountGeneration = library.accountGeneration
        searchIndexRevision = library.searchIndexRevision
        summaries = library.summaries
    }
}

extension LibraryStore {
    /// Search the account's local summaries and cached bodies without changing
    /// the list's query/advanced filters or fetching any content from the NAS.
    func globalSearch(query: String) async throws -> [NoteSummary] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration, repo = repository
        let bodyMatches = query.isEmpty ? Set<UUID>() : try await repo.searchNoteIDs(query)
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
        let matches = summaries.filter { note in
            !note.isTrashed && (query.isEmpty || bodyMatches.contains(note.id) ||
                "\(note.title) \(note.excerpt) \(note.tags.joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
        return NoteListSort(field: .modifiedAt, direction: .descending).sorted(matches)
    }
}
