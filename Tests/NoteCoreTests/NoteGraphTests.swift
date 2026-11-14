import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct NoteGraphTests {
    private func makeRepository() throws -> (NoteRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try NoteRepository(directory: directory), directory)
    }

    @Test func directedLinksAreDeduplicatedAndPreserveMarkdown() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await repo.save(NoteRecord(title: "A", markdown: "[한 번](B.md)\n[두 번](B.md)"), enqueue: false)
        let b = try await repo.save(NoteRecord(title: "B", markdown: "[반대](A.md)"), enqueue: false)
        let graph = try await repo.noteGraph()
        #expect(Set(graph.nodes.map(\.id)) == [a.id, b.id])
        #expect(Set(graph.edges) == [NoteGraphEdge(sourceID: a.id, targetID: b.id), NoteGraphEdge(sourceID: b.id, targetID: a.id)])
        #expect(try await repo.note(id: a.id)?.markdown == a.markdown)
    }

    @Test func ambiguousTitleDoesNotMakeAnEdge() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await repo.save(NoteRecord(title: "시작", markdown: "[모호](같은.md)"), enqueue: false)
        let a = try await repo.save(NoteRecord(title: "같은"), enqueue: false)
        let b = try await repo.save(NoteRecord(title: "같은"), enqueue: false)
        #expect(try await repo.noteGraph().edges.isEmpty)
        var trashed = b; trashed.isTrashed = true
        _ = try await repo.save(trashed, enqueue: false)
        let graph = try await repo.noteGraph()
        #expect(graph.edges == [NoteGraphEdge(sourceID: source.id, targetID: a.id)])
        #expect(!graph.nodes.map(\.id).contains(b.id))
    }

    @Test func renamesAndReopenRetainRecordedTargets() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await repo.save(NoteRecord(title: "시작", markdown: "[대상](<옛 이름.md>)"), enqueue: false)
        var target = try await repo.save(NoteRecord(title: "옛 이름"), enqueue: false)
        target.title = "새 이름"
        target = try await repo.save(target, enqueue: false)
        let edges = [NoteGraphEdge(sourceID: source.id, targetID: target.id)]
        #expect(try await repo.noteGraph().edges == edges)
        let reopened = try NoteRepository(directory: dir)
        #expect(try await reopened.noteGraph().edges == edges)
        #expect(try await reopened.note(id: source.id)?.markdown == source.markdown)
    }

    @Test func deletedAndTrashedNotesDisappearWithoutDanglingEdges() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await repo.save(NoteRecord(title: "시작", markdown: "[A](A.md)"), enqueue: false)
        var target = try await repo.save(NoteRecord(title: "A"), enqueue: false)
        _ = try await repo.resolveLink("A.md", from: source.id)
        target.isTrashed = true
        _ = try await repo.save(target, enqueue: false)
        #expect(try await repo.noteGraph().edges.isEmpty)
        #expect(try await repo.noteGraph().nodes.map(\.id) == [source.id])
        target.isTrashed = false
        _ = try await repo.save(target, enqueue: false)
        #expect(try await repo.noteGraph().edges.count == 1)
    }

    @Test func lateArrivingTargetsAndEditedLinksUpdateGraph() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        var source = try await repo.save(NoteRecord(title: "시작", markdown: "[나중](나중.md)"), enqueue: false)
        #expect(try await repo.noteGraph().edges.isEmpty)
        let target = try await repo.save(NoteRecord(title: "나중"), enqueue: false)
        #expect(try await repo.noteGraph().edges == [NoteGraphEdge(sourceID: source.id, targetID: target.id)])
        source.markdown = "링크 없음"
        _ = try await repo.save(source, enqueue: false)
        #expect(try await repo.noteGraph().edges.isEmpty)
    }

    @Test func neighborhoodRespectsDepthCyclesAndDirection() {
        let ids = (0..<5).map { _ in UUID() }
        let nodes = ids.enumerated().map { NoteGraphNode(id: $0.element, title: "\($0.offset)", notebookID: "one", tags: []) }
        let edges = [NoteGraphEdge(sourceID: ids[0], targetID: ids[1]),
                     NoteGraphEdge(sourceID: ids[2], targetID: ids[1]),
                     NoteGraphEdge(sourceID: ids[2], targetID: ids[0]),
                     NoteGraphEdge(sourceID: ids[3], targetID: ids[2]),
                     NoteGraphEdge(sourceID: ids[4], targetID: ids[3])]
        let graph = NoteGraph(nodes: nodes, edges: edges)
        #expect(Set(graph.neighborhood(of: ids[0], depth: 0).nodes.map(\.id)) == [ids[0]])
        #expect(Set(graph.neighborhood(of: ids[0], depth: 1).nodes.map(\.id)) == [ids[0], ids[1], ids[2]])
        #expect(Set(graph.neighborhood(of: ids[0], depth: 2).nodes.map(\.id)) == [ids[0], ids[1], ids[2], ids[3]])
        #expect(Set(graph.neighborhood(of: ids[0], depth: 3).nodes.map(\.id)) == Set(ids))
        #expect(graph.neighborhood(of: UUID(), depth: 3).nodes.isEmpty)
        #expect(graph.neighborhood(of: ids[0], depth: 1).edges.contains(NoteGraphEdge(sourceID: ids[2], targetID: ids[1])))
    }

    @Test func filtersKeepOnlyEdgesWithinVisibleNodes() {
        let ids = (0..<3).map { _ in UUID() }
        let graph = NoteGraph(nodes: [
            NoteGraphNode(id: ids[0], title: "A", notebookID: "first", tags: ["work"]),
            NoteGraphNode(id: ids[1], title: "B", notebookID: "first", tags: ["private"]),
            NoteGraphNode(id: ids[2], title: "C", notebookID: "second", tags: ["work"])
        ], edges: [NoteGraphEdge(sourceID: ids[0], targetID: ids[1]),
                  NoteGraphEdge(sourceID: ids[0], targetID: ids[2])])
        #expect(graph.filtered(notebookID: "first").edges == [NoteGraphEdge(sourceID: ids[0], targetID: ids[1])])
        #expect(graph.filtered(tag: "work").edges == [NoteGraphEdge(sourceID: ids[0], targetID: ids[2])])
        #expect(graph.filtered(notebookID: "first", tag: "work").edges.isEmpty)
        #expect(graph.filtered(tag: "missing").nodes.isEmpty)
    }

    @Test func forceLayoutIsStableFiniteAndCoversNodes() {
        let ids = (0..<250).map { _ in UUID() }
        let graph = NoteGraph(nodes: ids.map { NoteGraphNode(id: $0, title: "N", notebookID: "x", tags: []) },
                              edges: (1..<ids.count).map { NoteGraphEdge(sourceID: ids[$0-1], targetID: ids[$0]) })
        let result = NoteGraphLayout.positions(for: graph)
        #expect(result.count == ids.count)
        #expect(result == NoteGraphLayout.positions(for: graph))
        #expect(result.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1 && abs($0.y) <= 1 })
    }

    @Test func denseHubLayoutKeepsNodesSeparated() {
        let ids = (0..<615).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", $0 + 1))! }
        let nodes = ids.enumerated().map { NoteGraphNode(id: $0.element, title: "Note \($0.offset)", notebookID: "work", tags: []) }
        var edges = (1..<ids.count).map { NoteGraphEdge(sourceID: ids[0], targetID: ids[$0]) }
        edges += (1..<ids.count).map { NoteGraphEdge(sourceID: ids[$0 - 1], targetID: ids[$0]) }
        edges += (1..<ids.count - 1).map { NoteGraphEdge(sourceID: ids[$0], targetID: ids[$0 + 1]) }
        let graph = NoteGraph(nodes: nodes, edges: edges)
        let positions = NoteGraphLayout.positions(for: graph)
        #expect(positions.count == ids.count)
        #expect(positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let points = ids.compactMap { positions[$0] }
        var minDistance = Double.infinity
        for i in points.indices {
            for j in (i + 1)..<points.count {
                minDistance = min(minDistance, hypot(points[i].x - points[j].x, points[i].y - points[j].y))
            }
        }
        #expect(minDistance >= 0.022, "A dense graph must keep a usable visual distance between nodes")
    }

    @Test func disconnectedClustersHaveDistinctRegions() {
        let ids = (0..<14).map { UUID(uuidString: String(format: "10000000-0000-0000-0000-%012X", $0 + 1))! }
        let nodes = ids.map { NoteGraphNode(id: $0, title: "N", notebookID: "work", tags: []) }
        let edges = (1..<7).map { NoteGraphEdge(sourceID: ids[0], targetID: ids[$0]) }
                  + (8..<14).map { NoteGraphEdge(sourceID: ids[7], targetID: ids[$0]) }
        let positions = NoteGraphLayout.positions(for: NoteGraph(nodes: nodes, edges: edges))
        let first = ids[0..<7].compactMap { positions[$0] }
        let second = ids[7..<14].compactMap { positions[$0] }
        let a = (first.map(\.x).min()!, first.map(\.x).max()!, first.map(\.y).min()!, first.map(\.y).max()!)
        let b = (second.map(\.x).min()!, second.map(\.x).max()!, second.map(\.y).min()!, second.map(\.y).max()!)
        #expect(a.1 < b.0 || b.1 < a.0 || a.3 < b.2 || b.3 < a.2)
    }

    @Test func isolatesCanBeHiddenAndIncomingOutgoingLinksStayDirected() {
        let ids = (0..<4).map { _ in UUID() }
        let nodes = ids.enumerated().map { NoteGraphNode(id: $0.element, title: "N\($0.offset)", notebookID: "a", tags: []) }
        let graph = NoteGraph(nodes: nodes, edges: [
            NoteGraphEdge(sourceID: ids[0], targetID: ids[1]),
            NoteGraphEdge(sourceID: ids[2], targetID: ids[0])
        ])
        #expect(graph.excludingIsolated().nodes.count == 3)
        #expect(graph.excludingIsolated().edges == graph.edges)
        let links = graph.connections(of: ids[0])
        #expect(links.outgoing.map(\.id) == [ids[1]])
        #expect(links.incoming.map(\.id) == [ids[2]])
        #expect(graph.connections(of: ids[3]).incoming.isEmpty)
    }

    @Test func labelPlacementAlwaysPrefersSelectedAndAvoidsOverlap() {
        let ids = (0..<4).map { _ in UUID() }
        let graph = NoteGraph(nodes: ids.enumerated().map {
            NoteGraphNode(id: $0.element, title: "동일 좌표 제목 \($0.offset)", notebookID: "a", tags: [])
        })
        let locations: [UUID: NoteGraphPoint] = [
            ids[0]: .init(x: 0, y: 0), ids[1]: .init(x: 0, y: 0),
            ids[2]: .init(x: 0.8, y: 0), ids[3]: .init(x: -0.8, y: 0)
        ]
        let visible = NoteGraphLabelLayout.visibleIDs(
            graph: graph, positions: locations, width: 900, height: 700,
            zoom: 1, offsetX: 0, offsetY: 0, selectedID: ids[1], hoveredID: nil, query: "")
        #expect(visible.contains(ids[1]))
        #expect(!visible.contains(ids[0]))
    }

    @Test @MainActor func graphSnapshotRestoresSelectionFocusAndViewport() {
        let a = UUID(), b = UUID()
        let navigation = NoteGraphNavigation()
        navigation.zoom = 1.7
        navigation.pan = CGSize(width: 34, height: -12)
        let original = navigation.snapshot
        navigation.select(a)
        let selected = navigation.snapshot
        navigation.focus(on: b)
        navigation.zoom = 2.4
        navigation.pan = CGSize(width: 80, height: 45)
        navigation.restore(selected)
        #expect(navigation.selectedID == a)
        #expect(navigation.focusID == nil)
        #expect(navigation.zoom == 1.7)
        #expect(navigation.pan == CGSize(width: 34, height: -12))
        navigation.restore(original)
        #expect(navigation.selectedID == nil)
    }

    @Test @MainActor func pickingSearchResultShowsTheSelectedNoteDetails() {
        let navigation = NoteGraphNavigation()
        navigation.query = "report"
        let selected = UUID()
        navigation.select(selected)
        #expect(navigation.selectedID == selected)
        #expect(navigation.query.isEmpty)
    }

    @Test @MainActor func filteredOutSelectionCannotDimUnrelatedGraph() {
        let selected = UUID(), other = UUID()
        let navigation = NoteGraphNavigation()
        navigation.select(selected)
        let filtered = NoteGraph(nodes: [
            NoteGraphNode(id: other, title: "Visible", notebookID: "another", tags: [])
        ])
        navigation.reconcileSelection(in: filtered)
        #expect(navigation.selectedID == nil)
    }

    @Test @MainActor func graphNavigationUsesSameNoteEventAsLinks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryStore(root: dir, profile: ConnectionProfile())
        let target = try await store.repository.save(NoteRecord(title: "대상"), enqueue: false)
        try await store.reload()
        #expect(store.noteGraph.nodes.map(\.id) == [target.id])
        #expect(store.filtered(.graph).map(\.id) == [target.id])
    }

    @Test @MainActor func switchingAccountsNeverMixesGraphSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://nas.example", username: "a"))
        let b = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://nas.example", username: "b"))
        let saved = try await a.repository.save(NoteRecord(title: "A"), enqueue: false)
        try await a.reload()
        try await b.reload()
        #expect(a.noteGraph.nodes.map(\.id) == [saved.id])
        #expect(b.noteGraph.nodes.isEmpty)
    }
}
