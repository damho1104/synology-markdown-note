import Foundation

/// Restores the entire graph screen when visiting it through the app toolbar.
struct NoteGraphSnapshot: Equatable {
    var selectedID: UUID?
    var focusID: UUID?
    var depth: Int = 1
    var notebookID: String = ""
    var tag: String = ""
    var query: String = ""
    var includeIsolated: Bool = false
    var zoom: Double = 1
    var pan: CGSize = .zero

    /// Panning, zooming and typing refine the current view; selecting, focusing
    /// or changing graph scope visits a new view in the shared history.
    func isNewVisit(comparedTo previous: Self) -> Bool {
        selectedID != previous.selectedID || focusID != previous.focusID ||
        depth != previous.depth || notebookID != previous.notebookID ||
        tag != previous.tag || includeIsolated != previous.includeIsolated
    }
}

struct NoteNavigationHistory {
    struct Location: Equatable {
        var selection: UUID?
        var filter: LibraryFilter
        var search: String = ""
        var advancedTitle: String = ""
        var advancedTag: String = ""
        var advancedNotebookID: String?
        var advancedAfter: Date?
        var advancedBefore: Date?
        var graph: NoteGraphSnapshot?

        func reconciled(notebookIDs: Set<String>, stackNames: Set<String>, savedSearchIDs: Set<UUID>) -> Self {
            var location = self
            switch filter {
            case .notebook(let id) where !notebookIDs.contains(id): location.filter = .all
            case .stack(let name) where !stackNames.contains(name): location.filter = .all
            case .smart(let id) where !savedSearchIDs.contains(id): location.filter = .all
            default: break
            }
            if let advancedNotebookID, !notebookIDs.contains(advancedNotebookID) {
                location.advancedNotebookID = nil
            }
            return location
        }
    }

    private(set) var current: Location?
    private var previous: [Location] = []
    private var next: [Location] = []

    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !next.isEmpty }

    mutating func openGlobalSearchResult(_ id: UUID, from origin: Location) -> Location {
        let destination = Location(selection: id, filter: .all)
        navigate(from: origin, to: destination)
        return destination
    }

    mutating func observeSelection(_ location: Location, previousID: UUID?) {
        guard current != location else { return }
        // The sidebar transition owns its history entry when selection and
        // filter change together in one SwiftUI update.
        if let current, current.filter != location.filter { return }
        if current == nil && location.selection == nil {
            current = location
            return
        }
        let origin = current ?? Location(selection: previousID, filter: location.filter, search: location.search)
        if origin.selection != location.selection && origin.selection != nil {
            remember(origin)
        }
        current = location
    }

    mutating func replaceCurrent(_ location: Location) {
        current = location
    }

    mutating func updateContext(from previousLocation: Location, to location: Location) {
        guard previousLocation.selection == location.selection,
              previousLocation.filter == location.filter else { return }
        if let before = previousLocation.graph, let after = location.graph,
           after.isNewVisit(comparedTo: before) { return }
        current = location
    }

    mutating func observeGraphChange(from previous: NoteGraphSnapshot, to new: NoteGraphSnapshot,
                                     location: Location) {
        guard location.filter == .graph, current != location else { return }
        if new.isNewVisit(comparedTo: previous) {
            var origin = current ?? location
            origin.graph = previous
            navigate(from: origin, to: location)
        } else {
            replaceCurrent(location)
        }
    }

    mutating func navigate(from origin: Location, to destination: Location) {
        guard origin != destination else { current = destination; return }
        remember(origin)
        current = destination
    }

    mutating func goBack(allowing isAvailable: (Location) -> Bool) -> Location? {
        while let destination = previous.popLast() {
            guard isAvailable(destination) else { continue }
            if let current { next.append(current) }
            current = destination
            return destination
        }
        return nil
    }

    mutating func goForward(allowing isAvailable: (Location) -> Bool) -> Location? {
        while let destination = next.popLast() {
            guard isAvailable(destination) else { continue }
            if let current { previous.append(current) }
            current = destination
            return destination
        }
        return nil
    }

    private mutating func remember(_ location: Location) {
        previous.append(location)
        if previous.count > 100 { previous.removeFirst() }
        next.removeAll()
    }
}
