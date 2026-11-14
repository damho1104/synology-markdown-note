import Foundation

/// A read-only snapshot of locally indexed note relationships.
public struct NoteGraph: Hashable, Sendable {
    public var nodes: [NoteGraphNode]
    public var edges: [NoteGraphEdge]

    public init(nodes: [NoteGraphNode] = [], edges: [NoteGraphEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    /// Filters both endpoints, so a hidden note cannot leave a dangling edge.
    public func filtered(notebookID: String? = nil, tag: String? = nil) -> NoteGraph {
        let visible = nodes.filter { node in
            (notebookID == nil || node.notebookID == notebookID)
                && (tag == nil || node.tags.contains(tag!))
        }
        let ids = Set(visible.map(\.id))
        return NoteGraph(nodes: visible, edges: edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) })
    }

    /// Explore incoming and outgoing connections without changing edge direction.
    public func neighborhood(of center: UUID, depth: Int) -> NoteGraph {
        guard nodes.contains(where: { $0.id == center }) else { return NoteGraph() }
        let limit = max(0, min(3, depth))
        var adjacency: [UUID: Set<UUID>] = [:]
        for edge in edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }
        var seen: Set<UUID> = [center]
        var frontier: Set<UUID> = [center]
        for _ in 0..<limit {
            let next = Set(frontier.flatMap { adjacency[$0] ?? [] }).subtracting(seen)
            guard !next.isEmpty else { break }
            seen.formUnion(next)
            frontier = next
        }
        return NoteGraph(nodes: nodes.filter { seen.contains($0.id) },
                         edges: edges.filter { seen.contains($0.sourceID) && seen.contains($0.targetID) })
    }

    /// Linked-only view used by the full graph. Apply notebook/tag filters first.
    public func excludingIsolated() -> NoteGraph {
        let linked = Set(edges.flatMap { [$0.sourceID, $0.targetID] })
        return NoteGraph(nodes: nodes.filter { linked.contains($0.id) }, edges: edges)
    }

    public func connections(of id: UUID) -> NoteGraphConnections {
        let incomingIDs = Set(edges.filter { $0.targetID == id }.map(\.sourceID))
        let outgoingIDs = Set(edges.filter { $0.sourceID == id }.map(\.targetID))
        func sortedNodes(_ ids: Set<UUID>) -> [NoteGraphNode] {
            nodes.filter { ids.contains($0.id) }.sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }
        }
        return NoteGraphConnections(incoming: sortedNodes(incomingIDs), outgoing: sortedNodes(outgoingIDs))
    }
}

public struct NoteGraphConnections: Sendable {
    public let incoming: [NoteGraphNode]
    public let outgoing: [NoteGraphNode]
}

public struct NoteGraphNode: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let notebookID: String
    public let tags: [String]

    public init(id: UUID, title: String, notebookID: String, tags: [String]) {
        self.id = id; self.title = title; self.notebookID = notebookID; self.tags = tags
    }
}

public struct NoteGraphEdge: Hashable, Sendable {
    public let sourceID: UUID
    public let targetID: UUID

    public init(sourceID: UUID, targetID: UUID) {
        self.sourceID = sourceID; self.targetID = targetID
    }
}

public struct NoteGraphPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Approximate text bounds at canvas scale. Prioritize the selected note and
/// searches, then connected hubs; never place two labels over one another.
public enum NoteGraphLabelLayout {
    public static func visibleIDs(graph: NoteGraph, positions: [UUID: NoteGraphPoint],
                                  width: Double, height: Double, zoom: Double,
                                  offsetX: Double, offsetY: Double,
                                  selectedID: UUID?, hoveredID: UUID?, query: String) -> Set<UUID> {
        guard width > 0, height > 0 else { return [] }
        var degree: [UUID: Int] = [:]
        for edge in graph.edges {
            degree[edge.sourceID, default: 0] += 1
            degree[edge.targetID, default: 0] += 1
        }
        let matches = Set(graph.nodes.filter {
            !query.isEmpty && $0.title.localizedCaseInsensitiveContains(query)
        }.map(\.id))
        let prioritized = graph.nodes.sorted {
            func rank(_ node: NoteGraphNode) -> Int {
                if node.id == selectedID { return 1_000_000 }
                if node.id == hoveredID { return 900_000 }
                if matches.contains(node.id) { return 800_000 }
                return min(10000, degree[node.id, default: 0])
            }
            let a = rank($0), b = rank($1)
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
        let scale = min(width, height) * 0.43 * zoom
        var occupied: [(left: Double, right: Double, top: Double, bottom: Double)] = []
        var visible = Set<UUID>()
        for node in prioritized {
            guard let point = positions[node.id] else { continue }
            let x = width / 2 + point.x * scale + offsetX
            let y = height / 2 + point.y * scale + offsetY
            // Text rendering uses the same maximum 28-character title.
            let labelWidth = Double(min(node.title.count, 28)) * 6.3 + 12
            let radius = 5.0 + min(4, sqrt(Double(degree[node.id, default: 0])) * 0.7)
            let rect = (left: x - labelWidth / 2, right: x + labelWidth / 2,
                        top: y + radius + 4, bottom: y + radius + 19)
            guard rect.right > 0, rect.left < width, rect.bottom > 0, rect.top < height else { continue }
            if occupied.contains(where: {
                $0.left - 3 < rect.right && $0.right + 3 > rect.left
                    && $0.top - 2 < rect.bottom && $0.bottom + 2 > rect.top
            }) { continue }
            visible.insert(node.id)
            occupied.append(rect)
        }
        return visible
    }
}

/// Deterministic component-aware layout; does not access SQLite or the main actor.
public enum NoteGraphLayout {
    public static func positions(for graph: NoteGraph) -> [UUID: NoteGraphPoint] {
        let nodes = graph.nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let count = nodes.count
        guard count > 0 else { return [:] }
        guard count > 1 else { return [nodes[0].id: NoteGraphPoint(x: 0, y: 0)] }
        let ids = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let links = graph.edges.compactMap { edge -> (Int, Int)? in
            guard let a = ids[edge.sourceID], let b = ids[edge.targetID], a != b else { return nil }
            return (a, b)
        }
        var adjacency = Array(repeating: [Int](), count: count)
        var degrees = Array(repeating: 0, count: count)
        for (a, b) in links {
            adjacency[a].append(b); adjacency[b].append(a)
            degrees[a] += 1; degrees[b] += 1
        }

        // Pack independent components in separate rectangles so they never overlap.
        var visited = Set<Int>()
        var components: [[Int]] = []
        for start in 0..<count where !visited.contains(start) {
            var queue = [start], cursor = 0
            visited.insert(start)
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                for neighbor in adjacency[index] where visited.insert(neighbor).inserted {
                    queue.append(neighbor)
                }
            }
            components.append(queue.sorted { degrees[$0] == degrees[$1] ? $0 < $1 : degrees[$0] > degrees[$1] })
        }
        components.sort { $0.count == $1.count ? $0[0] < $1[0] : $0.count > $1.count }

        var localPoints = Array(repeating: NoteGraphPoint(x: 0, y: 0), count: count)
        var rectangles: [(members: [Int], width: Double, height: Double)] = []
        for members in components {
            for (order, index) in members.enumerated() {
                let angle = Double(order) * 2.399963229728653
                let radius = order == 0 ? 0 : 1.65 * sqrt(Double(order))
                localPoints[index] = NoteGraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            let memberSet = Set(members)
            let componentLinks = links.filter { memberSet.contains($0.0) && memberSet.contains($0.1) }
            // A hub's hundreds of edges must not pull all its neighbors into one pixel.
            for step in 0..<(members.count > 1000 ? 42 : 70) {
                var forces = Array(repeating: NoteGraphPoint(x: 0, y: 0), count: count)
                for (a, b) in componentLinks {
                    let dx = localPoints[b].x - localPoints[a].x
                    let dy = localPoints[b].y - localPoints[a].y
                    let distance = max(0.001, hypot(dx, dy))
                    let pull = min(0.045, max(0, distance - 2.2) * 0.0018)
                    let fx = dx / distance * pull, fy = dy / distance * pull
                    let aWeight = 1.0 / sqrt(Double(max(1, degrees[a])))
                    let bWeight = 1.0 / sqrt(Double(max(1, degrees[b])))
                    forces[a].x += fx * aWeight; forces[a].y += fy * aWeight
                    forces[b].x -= fx * bWeight; forces[b].y -= fy * bWeight
                }
                let cooling = 1.0 - Double(step) / 110.0
                for index in members {
                    localPoints[index].x += forces[index].x * cooling
                    localPoints[index].y += forces[index].y * cooling
                }
                // Resolve ALL close pairs, including pairs omitted by graph edges.
                for i in members.indices {
                    for j in (i + 1)..<members.count {
                        let a = members[i], b = members[j]
                        var dx = localPoints[b].x - localPoints[a].x
                        var dy = localPoints[b].y - localPoints[a].y
                        if dx == 0 && dy == 0 { dx = 0.0001; dy = 0.0001 }
                        let distance2 = dx * dx + dy * dy
                        if distance2 >= 1.65 * 1.65 { continue }
                        let distance = sqrt(distance2)
                        let push = (1.65 - distance) * 0.52 / distance
                        localPoints[a].x -= dx * push; localPoints[a].y -= dy * push
                        localPoints[b].x += dx * push; localPoints[b].y += dy * push
                    }
                }
            }
            let minX = members.map { localPoints[$0].x }.min()!
            let minY = members.map { localPoints[$0].y }.min()!
            let maxX = members.map { localPoints[$0].x }.max()!
            let maxY = members.map { localPoints[$0].y }.max()!
            for index in members {
                localPoints[index].x -= minX
                localPoints[index].y -= minY
            }
            rectangles.append((members, maxX - minX + 3, maxY - minY + 3))
        }
        let largest = rectangles.map(\.width).max() ?? 1
        let targetRowWidth = max(largest, sqrt(Double(count)) * 3.6)
        var rowX = 0.0, rowY = 0.0, rowHeight = 0.0
        var maxX = 0.0
        for rect in rectangles {
            if rowX > 0 && rowX + rect.width > targetRowWidth {
                rowX = 0; rowY += rowHeight + 2; rowHeight = 0
            }
            for index in rect.members {
                localPoints[index].x += rowX + 1.5
                localPoints[index].y += rowY + 1.5
            }
            rowX += rect.width + 2
            maxX = max(maxX, rowX)
            rowHeight = max(rowHeight, rect.height)
        }
        let maxY = rowY + rowHeight
        let scale = 1.7 / max(0.001, max(maxX, maxY))
        return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { index, node in
            (node.id, NoteGraphPoint(x: (localPoints[index].x - maxX / 2) * scale,
                                     y: (localPoints[index].y - maxY / 2) * scale))
        })
    }
}
