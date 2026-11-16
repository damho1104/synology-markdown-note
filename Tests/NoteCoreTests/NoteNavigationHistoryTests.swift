import Foundation
import Testing
@testable import SynologyNote

@Suite struct NoteNavigationHistoryTests {
    @Test func globalSearchClearsFiltersAndRestoresGraphThroughSharedHistory() {
        let target = UUID()
        var origin = NoteNavigationHistory.Location(selection: UUID(), filter: .graph, search: "목록 검색")
        origin.advancedTitle = "제목 조건"
        origin.advancedTag = "태그"
        origin.advancedNotebookID = "book"
        origin.advancedAfter = Date(timeIntervalSince1970: 100)
        origin.advancedBefore = Date(timeIntervalSince1970: 200)
        origin.graph = NoteGraphSnapshot(selectedID: target, focusID: target, depth: 2, query: "그래프 검색", zoom: 2)
        var history = NoteNavigationHistory()
        let destination = history.openGlobalSearchResult(target, from: origin)
        #expect(destination == NoteNavigationHistory.Location(selection: target, filter: .all))
        history.observeSelection(destination, previousID: origin.selection)
        #expect(history.goBack(allowing: { _ in true }) == origin)
        #expect(!history.canGoBack)
        #expect(history.goForward(allowing: { _ in true }) == destination)
    }

    @Test func globalSearchOfSelectedNoteStillPreservesPreviousNotebookAndFilters() {
        let target = UUID()
        let origin = NoteNavigationHistory.Location(selection: target, filter: .notebook("book"), search: "목록 검색")
        var history = NoteNavigationHistory()
        let destination = history.openGlobalSearchResult(target, from: origin)
        #expect(destination == NoteNavigationHistory.Location(selection: target, filter: .all))
        #expect(history.goBack(allowing: { _ in true }) == origin)
    }

    private func location(_ id: UUID?, filter: LibraryFilter = .all, search: String = "") -> NoteNavigationHistory.Location {
        NoteNavigationHistory.Location(selection: id, filter: filter, search: search)
    }

    @Test func linkedNoteBackAndForwardRestoreOriginContext() {
        let source = UUID(), target = UUID()
        let origin = location(source, filter: .notebook("source"), search: "daily")
        let destination = location(target)
        var history = NoteNavigationHistory()
        history.observeSelection(origin, previousID: nil)
        history.navigate(from: origin, to: destination)

        #expect(history.canGoBack)
        #expect(history.goBack(allowing: { _ in true }) == origin)
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
        #expect(history.goForward(allowing: { _ in true }) == destination)
        #expect(!history.canGoForward)
    }

    @Test func manualSelectionBuildsHistoryAndNewVisitClearsForward() {
        let first = UUID(), second = UUID(), third = UUID()
        var history = NoteNavigationHistory()
        history.observeSelection(location(first), previousID: nil)
        history.observeSelection(location(second), previousID: first)
        #expect(history.goBack(allowing: { _ in true })?.selection == first)
        history.observeSelection(location(third), previousID: first)
        #expect(!history.canGoForward)
        #expect(history.goBack(allowing: { _ in true })?.selection == first)
    }

    @Test func graphNavigationAndMissingNotesAreHandled() {
        let deleted = UUID(), target = UUID()
        var history = NoteNavigationHistory()
        history.observeSelection(location(deleted), previousID: nil)
        history.observeSelection(location(target), previousID: deleted)
        history.replaceCurrent(location(target, filter: .graph))
        history.navigate(from: location(target, filter: .graph), to: location(target))
        #expect(history.goBack(allowing: { _ in true })?.filter == .graph)
        #expect(history.goBack(allowing: { $0.selection != deleted }) == nil)
        #expect(!history.canGoBack)
    }

    @Test func duplicateSelectionDoesNotAddHistory() {
        let id = UUID()
        var history = NoteNavigationHistory()
        history.observeSelection(location(id), previousID: nil)
        history.observeSelection(location(id), previousID: id)
        history.replaceCurrent(location(id, filter: .notebook("work")))
        #expect(!history.canGoBack)
    }

    @Test func initialEmptySelectionDoesNotRestoreAnOldAccountNote() {
        let oldAccountNote = UUID()
        var history = NoteNavigationHistory()
        history.observeSelection(location(nil), previousID: oldAccountNote)
        #expect(!history.canGoBack)
    }

    @Test func sameNoteNavigationRestoresSearchFilters() {
        let id = UUID()
        var history = NoteNavigationHistory()
        var source = location(id, filter: .smart(UUID()), search: "meeting")
        source.advancedTag = "work"
        source.advancedNotebookID = "private"
        history.navigate(from: source, to: location(id))
        #expect(history.goBack(allowing: { _ in true }) == source)
    }

    @Test func changedAdvancedFiltersRemainInHistoryForManualSelection() {
        let first = UUID(), second = UUID()
        var history = NoteNavigationHistory()
        var source = location(first)
        history.observeSelection(source, previousID: nil)
        source.advancedTag = "work"
        source.advancedAfter = Date(timeIntervalSince1970: 1234)
        history.updateContext(from: location(first), to: source)
        var destination = source
        destination.selection = second
        history.observeSelection(destination, previousID: first)
        #expect(history.goBack(allowing: { _ in true }) == source)
    }

    @Test func contextUpdateCannotOverwritePreviousNoteBeforeSelectionIsRecorded() {
        let first = UUID(), second = UUID()
        var history = NoteNavigationHistory()
        let source = location(first)
        let destination = location(second)
        history.observeSelection(source, previousID: nil)
        history.updateContext(from: source, to: destination)
        history.observeSelection(destination, previousID: first)
        #expect(history.goBack(allowing: { _ in true }) == source)
    }

    @Test func removedFiltersRestoreNoteUsingAllNotes() {
        for filter in [LibraryFilter.stack("renamed"), .notebook("deleted"), .smart(UUID())] {
            var source = location(UUID(), filter: filter, search: "report")
            source.advancedNotebookID = "deleted"
            let restored = source.reconciled(notebookIDs: [], stackNames: [], savedSearchIDs: [])
            #expect(restored.filter == .all)
            #expect(restored.selection == source.selection)
            #expect(restored.search == "report")
            #expect(restored.advancedNotebookID == nil)
        }
    }

    @Test func existingFiltersRemainUnchangedOnRestore() {
        let smartID = UUID()
        for filter in [LibraryFilter.stack("work"), .notebook("book"), .smart(smartID)] {
            var source = location(UUID(), filter: filter)
            source.advancedNotebookID = "book"
            #expect(source.reconciled(notebookIDs: ["book"], stackNames: ["work"], savedSearchIDs: [smartID]) == source)
        }
    }

    @Test func sidebarAndGraphViewsShareOneBackForwardTimeline() {
        let noteID = UUID(), graphNoteID = UUID()
        let notes = location(noteID)
        let notebook = location(noteID, filter: .notebook("work"))
        let graphStart = NoteGraphSnapshot()
        var graph = location(noteID, filter: .graph)
        graph.graph = graphStart
        var history = NoteNavigationHistory()
        history.observeSelection(notes, previousID: nil)
        history.navigate(from: notes, to: notebook)
        history.navigate(from: notebook, to: graph)

        var selectedGraph = graph
        selectedGraph.graph?.selectedID = graphNoteID
        history.observeGraphChange(from: graphStart, to: selectedGraph.graph!, location: selectedGraph)

        var focusedGraph = selectedGraph
        focusedGraph.graph?.focusID = graphNoteID
        focusedGraph.graph?.zoom = 2
        history.observeGraphChange(from: selectedGraph.graph!, to: focusedGraph.graph!, location: focusedGraph)

        #expect(history.goBack(allowing: { _ in true }) == selectedGraph)
        #expect(history.goBack(allowing: { _ in true }) == graph)
        #expect(history.goBack(allowing: { _ in true }) == notebook)
        #expect(history.goBack(allowing: { _ in true }) == notes)
        #expect(history.goForward(allowing: { _ in true }) == notebook)
        #expect(history.goForward(allowing: { _ in true }) == graph)
        #expect(history.goForward(allowing: { _ in true }) == selectedGraph)
        #expect(history.goForward(allowing: { _ in true }) == focusedGraph)
    }

    @Test func graphViewportUpdatesDoNotFloodHistoryAndRestoreOnBack() {
        let note = location(UUID())
        let initialGraph = NoteGraphSnapshot()
        var graph = location(nil, filter: .graph)
        graph.graph = initialGraph
        var history = NoteNavigationHistory()
        history.observeSelection(note, previousID: nil)
        history.navigate(from: note, to: graph)

        var moved = graph
        moved.graph?.pan = CGSize(width: 120, height: 30)
        moved.graph?.zoom = 1.8
        history.updateContext(from: graph, to: moved)
        history.observeGraphChange(from: initialGraph, to: moved.graph!, location: moved)

        var selected = moved
        selected.graph?.selectedID = UUID()
        history.updateContext(from: moved, to: selected)
        history.observeGraphChange(from: moved.graph!, to: selected.graph!, location: selected)
        #expect(history.goBack(allowing: { _ in true }) == moved)
        #expect(history.goBack(allowing: { _ in true }) == note)
        #expect(history.goForward(allowing: { _ in true }) == moved)
        history.navigate(from: moved, to: location(UUID()))
        #expect(!history.canGoForward)
    }

    @Test func changingSidebarContextDoesNotEraseGraphOrigin() {
        let id = UUID()
        var graph = location(id, filter: .graph)
        graph.graph = NoteGraphSnapshot(selectedID: id, focusID: id)
        let next = location(id, filter: .favorites)
        var history = NoteNavigationHistory()
        history.observeSelection(graph, previousID: nil)
        history.observeSelection(next, previousID: id)
        #expect(!history.canGoBack)
        history.navigate(from: graph, to: next)
        #expect(history.goBack(allowing: { _ in true }) == graph)
    }
}
