import SwiftUI
import NoteCore
import Observation

/// Shared state between the graph canvas and the library's navigation column.
@MainActor @Observable final class NoteGraphNavigation {
    var selectedID: UUID?
    var focusID: UUID?
    var depth = 1
    var notebookID = ""
    var tag = ""
    var query = ""
    var includeIsolated = false
    var zoom = 1.0
    var pan: CGSize = .zero

    var snapshot: NoteGraphSnapshot {
        NoteGraphSnapshot(selectedID: selectedID, focusID: focusID, depth: depth,
                          notebookID: notebookID, tag: tag, query: query,
                          includeIsolated: includeIsolated, zoom: zoom, pan: pan)
    }

    func restore(_ snapshot: NoteGraphSnapshot) {
        selectedID = snapshot.selectedID
        focusID = snapshot.focusID
        depth = snapshot.depth
        notebookID = snapshot.notebookID
        tag = snapshot.tag
        query = snapshot.query
        includeIsolated = snapshot.includeIsolated
        zoom = snapshot.zoom
        pan = snapshot.pan
    }

    init(focusID: UUID? = nil) {
        self.focusID = focusID
        selectedID = focusID
    }

    func select(_ id: UUID) {
        guard selectedID != id else { query = ""; return }
        selectedID = id
        query = ""
    }

    func focus(on id: UUID) {
        guard focusID != id else { return }
        focusID = id
        selectedID = id
        zoom = 1
        pan = .zero
    }

    func showAll() {
        guard focusID != nil else { return }
        focusID = nil
        zoom = 1
        pan = .zero
    }

    func reconcileSelection(in graph: NoteGraph) {
        if let selectedID, !graph.nodes.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}

/// Shared explorer for the full library and the inspector's local neighborhood.
struct NoteGraphExplorer: View {
    let graph: NoteGraph
    let notebooks: [Notebook]
    let compact: Bool
    let onOpen: (UUID) -> Void
    let navigation: NoteGraphNavigation?
    @State private var localNavigation: NoteGraphNavigation
    @State private var positions: [UUID: NoteGraphPoint] = [:]

    init(graph: NoteGraph, notebooks: [Notebook], focusID: UUID? = nil,
         compact: Bool = false, navigation: NoteGraphNavigation? = nil,
         onOpen: @escaping (UUID) -> Void) {
        self.graph = graph; self.notebooks = notebooks; self.compact = compact; self.onOpen = onOpen
        self.navigation = navigation
        _localNavigation = State(initialValue: NoteGraphNavigation(focusID: focusID))
    }

    private var nav: NoteGraphNavigation { navigation ?? localNavigation }

    private var visible: NoteGraph {
        let filtered = graph.filtered(notebookID: nav.notebookID.isEmpty ? nil : nav.notebookID,
                                      tag: nav.tag.isEmpty ? nil : nav.tag)
        if let focusID = nav.focusID { return filtered.neighborhood(of: focusID, depth: nav.depth) }
        return nav.includeIsolated ? filtered : filtered.excludingIsolated()
    }

    private var hiddenCount: Int {
        guard !nav.includeIsolated && nav.focusID == nil else { return 0 }
        let filtered = graph.filtered(notebookID: nav.notebookID.isEmpty ? nil : nav.notebookID,
                                      tag: nav.tag.isEmpty ? nil : nav.tag)
        return filtered.nodes.count - visible.nodes.count
    }

    private var selected: NoteGraphNode? {
        visible.nodes.first(where: { $0.id == nav.selectedID })
    }

    var body: some View {
        @Bindable var state = nav
        VStack(spacing: 10) {
            if !compact {
                HStack(spacing: 8) {
                    TextField(appText("Search Note Titles"), text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(appText("Search Notes in Graph"))
                    Picker(appText("Notebook"), selection: $state.notebookID) {
                        Text(appText("All Notebooks")).tag("")
                        ForEach(notebooks) { book in Text(book.name).tag(book.id) }
                    }.frame(maxWidth: 175)
                    Picker(appText("Tags"), selection: $state.tag) {
                        Text(appText("All Tags")).tag("")
                        ForEach(Array(Set(graph.nodes.flatMap(\.tags))).sorted(), id: \.self) { item in
                            Text("#" + item).tag(item)
                        }
                    }.frame(maxWidth: 155)
                }
            }
            HStack {
                if let focusID = nav.focusID {
                    Text(appText("Local Graph")).font(.subheadline.weight(.semibold))
                    Picker(appText("Link Depth"), selection: $state.depth) {
                        ForEach(1...3, id: \.self) { Text(appText("%@", AppLocalization.number($0))).tag($0) }
                    }.pickerStyle(.menu).fixedSize()
                    if !compact {
                        Button(appText("Note Graph")) { nav.showAll() }
                            .help(appText("View All Note Links"))
                    }
                    // Keep the source of the local graph discoverable.
                    if !compact, let node = graph.nodes.first(where: { $0.id == focusID }) {
                        Text(node.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(appText("Note Graph")).font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 2)
                if !compact && nav.focusID == nil {
                    Toggle(appText("Unlinked Notes"), isOn: $state.includeIsolated)
                        .toggleStyle(.checkbox).font(.caption)
                }
                Text(appText("Notes: %1$@ · Links: %2$@", AppLocalization.number(visible.nodes.count), AppLocalization.number(visible.edges.count)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if hiddenCount > 0 {
                    Text(appText("(Unlinked notes hidden: %@)", AppLocalization.number(hiddenCount))).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if visible.nodes.isEmpty {
                ContentUnavailableView(appText("No Notes to Display"), systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(appText("Change the filters or add links between notes.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoteGraphCanvas(graph: visible, positions: positions, navigation: nav,
                                onOpen: onOpen, onFocus: { id in nav.focus(on: id) })
                    .frame(minHeight: compact ? 175 : 350)
                    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(appText("Note relationship graph. Double-click a node to open its note."))
            }
            if let selected {
                HStack(spacing: 8) {
                    Text(selected.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(appText("Open Note")) { onOpen(selected.id) }.buttonStyle(.borderless)
                    if !compact { Button(appText("Show Links Only")) { nav.focus(on: selected.id) }.buttonStyle(.borderless) }
                }
            } else if !compact {
                Text(appText("Select nodes · Double-click to open notes · Drag to pan · Pinch or use +/− to zoom"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 4 : 16)
        .task(id: visible) {
            let snapshot = visible
            nav.reconcileSelection(in: snapshot)
            let computed = await Task.detached(priority: .userInitiated) {
                NoteGraphLayout.positions(for: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            positions = computed
        }
        .onChange(of: nav.selectedID) { _, _ in nav.reconcileSelection(in: visible) }
        .onChange(of: nav.notebookID) { _, _ in
            if let id = nav.focusID, !graph.filtered(notebookID: nav.notebookID.isEmpty ? nil : nav.notebookID)
                .nodes.contains(where: { $0.id == id }) { nav.showAll() }
        }
        .onChange(of: nav.tag) { _, _ in
            if let id = nav.focusID, !graph.filtered(tag: nav.tag.isEmpty ? nil : nav.tag)
                .nodes.contains(where: { $0.id == id }) { nav.showAll() }
        }
    }
}

/// Uses the same palette in the graph and in the notebook legend.
private func graphNotebookColor(_ notebookID: String) -> Color {
    var hash: UInt64 = 14695981039346656037
    for byte in notebookID.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return Color(hue: Double(hash % 360) / 360, saturation: 0.64, brightness: 0.84)
}

/// The navigation split-view's middle column for the full graph.
struct NoteGraphNavigationPanel: View {
    let graph: NoteGraph
    let notebooks: [Notebook]
    let navigation: NoteGraphNavigation
    let onOpen: (UUID) -> Void

    private var filtered: NoteGraph {
        graph.filtered(notebookID: navigation.notebookID.isEmpty ? nil : navigation.notebookID,
                       tag: navigation.tag.isEmpty ? nil : navigation.tag)
    }

    private var visible: NoteGraph {
        if let focusID = navigation.focusID {
            return filtered.neighborhood(of: focusID, depth: navigation.depth)
        }
        return navigation.includeIsolated ? filtered : filtered.excludingIsolated()
    }

    private var selected: NoteGraphNode? {
        visible.nodes.first(where: { $0.id == navigation.selectedID })
    }

    private var ranked: [NoteGraphNode] {
        let count = degreeCounts
        return visible.nodes.sorted {
            let left = count[$0.id, default: 0], right = count[$1.id, default: 0]
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left > right
        }
    }

    private var degreeCounts: [UUID: Int] {
        var count: [UUID: Int] = [:]
        for edge in visible.edges {
            count[edge.sourceID, default: 0] += 1
            count[edge.targetID, default: 0] += 1
        }
        return count
    }

    private func notebookTitle(_ id: String) -> String {
        notebooks.first(where: { $0.id == id })?.name ?? id
    }

    private func noteRow(_ node: NoteGraphNode, connectionCount: Int? = nil) -> some View {
        Button { navigation.select(node.id) } label: {
            HStack(spacing: 7) {
                Circle().fill(graphNotebookColor(node.notebookID)).frame(width: 7, height: 7)
                Text(node.title.isEmpty ? appText("Untitled") : node.title)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let connectionCount {
                    Text(AppLocalization.number(connectionCount)).font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if navigation.selectedID == node.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .font(.subheadline).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appText("Select This Note in the Graph"))
    }

    private func connectionSection(_ title: String, nodes: [NoteGraphNode], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(appText("%1$@ · %2$@", title, AppLocalization.number(nodes.count))).font(.subheadline.weight(.semibold))
            }
            if nodes.isEmpty {
                Text(appText("No Links")).font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(nodes) { note in noteRow(note) }
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Label(appText("Note Link Map"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(appText("Notes: %1$@ · Links: %2$@", AppLocalization.number(visible.nodes.count), AppLocalization.number(visible.edges.count)))
                    .font(.caption).foregroundStyle(.secondary)
                if !navigation.query.isEmpty {
                    Divider()
                    let matches = visible.nodes.filter {
                        $0.title.localizedCaseInsensitiveContains(navigation.query)
                    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    Text(appText("Results: %@", AppLocalization.number(matches.count)))
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(matches.prefix(100))) { note in noteRow(note) }
                    if matches.count > 100 {
                        Text(appText("Showing the First 100")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let selected {
                    Divider()
                    Text(selected.title.isEmpty ? appText("Untitled") : selected.title)
                        .font(.headline).textSelection(.enabled)
                    Text(notebookTitle(selected.notebookID))
                        .font(.caption).foregroundStyle(.secondary)
                    if !selected.tags.isEmpty {
                        Text(selected.tags.map { "#" + $0 }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(appText("Open Note")) { onOpen(selected.id) }
                        Button(appText("Show Neighbors Only")) { navigation.focus(on: selected.id) }
                    }
                    .controlSize(.small)
                    Divider()
                    let connections = visible.connections(of: selected.id)
                    connectionSection(appText("Outgoing Links →"), nodes: connections.outgoing, color: .cyan)
                    Divider()
                    connectionSection(appText("← Incoming Links"), nodes: connections.incoming, color: .orange)
                } else {
                    Divider()
                    Text(appText("Top Notes")).font(.subheadline.weight(.semibold))
                    Text(appText("Most Linked First")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(ranked.prefix(16))) { note in
                        noteRow(note, connectionCount: degreeCounts[note.id, default: 0])
                    }
                }
                Divider()
                Text(appText("Notebook Colors")).font(.subheadline.weight(.semibold))
                ForEach(notebooks.filter({ book in visible.nodes.contains(where: { $0.notebookID == book.id }) })) { book in
                    HStack(spacing: 8) {
                        Circle().fill(graphNotebookColor(book.id)).frame(width: 9, height: 9)
                        Text(book.name).font(.caption)
                        Spacer()
                        Text("\(visible.nodes.filter { $0.notebookID == book.id }.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(appText("Blue: Outgoing links from the selected note · Orange: Incoming links"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(appText("Note Graph"))
    }
}

private struct NoteGraphCanvas: View {
    let graph: NoteGraph
    let positions: [UUID: NoteGraphPoint]
    let navigation: NoteGraphNavigation
    let onOpen: (UUID) -> Void
    let onFocus: (UUID) -> Void

    @State private var dragOrigin: CGSize?
    @State private var magnifyOrigin: Double?
    @State private var hoveredID: UUID?

    private var noteIDs: Set<UUID> {
        Set(graph.nodes.filter { !navigation.query.isEmpty && $0.title.localizedCaseInsensitiveContains(navigation.query) }.map(\.id))
    }

    private var degrees: [UUID: Int] {
        var values: [UUID: Int] = [:]
        for edge in graph.edges {
            values[edge.sourceID, default: 0] += 1
            values[edge.targetID, default: 0] += 1
        }
        return values
    }

    private func radius(for id: UUID, degrees: [UUID: Int]) -> CGFloat {
        min(9, 4.5 + sqrt(Double(degrees[id, default: 0])) * 0.78)
    }

    private func point(_ id: UUID, size: CGSize) -> CGPoint? {
        guard let item = positions[id] else { return nil }
        let scale = min(size.width, size.height) * 0.43 * navigation.zoom
        return CGPoint(x: size.width / 2 + item.x * scale + navigation.pan.width,
                       y: size.height / 2 + item.y * scale + navigation.pan.height)
    }

    private func hit(_ location: CGPoint, size: CGSize) -> UUID? {
        let degreeMap = degrees
        return graph.nodes.compactMap { node -> (UUID, CGFloat)? in
            guard let p = point(node.id, size: size) else { return nil }
            let distance = hypot(p.x - location.x, p.y - location.y)
            return distance <= max(13, radius(for: node.id, degrees: degreeMap) + 5) ? (node.id, distance) : nil
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func color(for notebookID: String) -> Color {
        graphNotebookColor(notebookID)
    }

    var body: some View {
        let selectedID = navigation.selectedID
        let query = navigation.query
        let zoom = navigation.zoom
        let pan = navigation.pan
        GeometryReader { proxy in
            Canvas { context, size in
                let matches = noteIDs
                let degreeMap = degrees
                let neighbors = Set(graph.edges.compactMap { edge -> UUID? in
                    if edge.sourceID == selectedID { return edge.targetID }
                    if edge.targetID == selectedID { return edge.sourceID }
                    return nil
                })
                let labels = NoteGraphLabelLayout.visibleIDs(
                    graph: graph, positions: positions,
                    width: Double(size.width), height: Double(size.height),
                    zoom: zoom, offsetX: Double(pan.width), offsetY: Double(pan.height),
                    selectedID: selectedID, hoveredID: hoveredID, query: query)
                for edge in graph.edges {
                    guard let a = point(edge.sourceID, size: size), let b = point(edge.targetID, size: size) else { continue }
                    var line = Path(); line.move(to: a); line.addLine(to: b)
                    let outgoing = selectedID != nil && edge.sourceID == selectedID
                    let incoming = selectedID != nil && edge.targetID == selectedID
                    let adjacent = outgoing || incoming
                    let matched = matches.contains(edge.sourceID) || matches.contains(edge.targetID)
                    let color: Color = outgoing ? .cyan : incoming ? .orange : .secondary
                    let opacity = adjacent ? 0.94 : selectedID != nil ? 0.045
                        : !query.isEmpty && !matched ? 0.045 : graph.edges.count > 500 ? 0.12 : 0.25
                    context.stroke(line, with: .color(color.opacity(opacity)),
                                   lineWidth: adjacent ? 2.2 : matched ? 1.35 : 0.75)
                    if adjacent {
                        let dx = b.x - a.x, dy = b.y - a.y
                        let length = max(1, hypot(dx, dy))
                        let ux = dx / length, uy = dy / length
                        let tip = CGPoint(x: b.x - ux * (radius(for: edge.targetID, degrees: degreeMap) + 2),
                                          y: b.y - uy * (radius(for: edge.targetID, degrees: degreeMap) + 2))
                        var arrow = Path()
                        arrow.move(to: tip)
                        arrow.addLine(to: CGPoint(x: tip.x - ux * 9 - uy * 4,
                                                  y: tip.y - uy * 9 + ux * 4))
                        arrow.addLine(to: CGPoint(x: tip.x - ux * 9 + uy * 4,
                                                  y: tip.y - uy * 9 - ux * 4))
                        arrow.closeSubpath()
                        context.fill(arrow, with: .color(color))
                    }
                }
                for node in graph.nodes {
                    guard let p = point(node.id, size: size) else { continue }
                    let selected = node.id == selectedID
                    let matched = matches.contains(node.id)
                    let faded = (selectedID != nil && !selected && !neighbors.contains(node.id) && !matched)
                        || (!query.isEmpty && !matched && !selected && !neighbors.contains(node.id))
                    let radius: CGFloat = selected ? 10 : matched ? 8.5 : min(9, 4.5 + sqrt(Double(degreeMap[node.id, default: 0])) * 0.78)
                    let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color(for: node.notebookID).opacity(faded ? 0.16 : 1)))
                    if selected || matched {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(selected ? .primary : .accentColor), lineWidth: 1.7)
                    }
                    if labels.contains(node.id) {
                        let title = node.title.isEmpty ? appText("Untitled") : String(node.title.prefix(28))
                        let labelWidth = CGFloat(min(node.title.count, 28)) * 6.3 + 12
                        let labelRect = CGRect(x: p.x - labelWidth / 2, y: p.y + radius + 4,
                                               width: labelWidth, height: 15)
                        context.fill(Path(roundedRect: labelRect, cornerRadius: 3),
                                     with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.83)))
                        context.draw(Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .foregroundColor(faded ? .secondary : .primary),
                            at: CGPoint(x: p.x, y: p.y + radius + 5), anchor: .top)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoveredID = hit(point, size: proxy.size)
                case .ended: hoveredID = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { event in
                if let id = hit(event.location, size: proxy.size) { onOpen(id) }
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                if let id = hit(event.location, size: proxy.size) { navigation.select(id) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                if dragOrigin == nil { dragOrigin = navigation.pan }
                navigation.pan = CGSize(width: (dragOrigin?.width ?? 0) + value.translation.width,
                                        height: (dragOrigin?.height ?? 0) + value.translation.height)
            }.onEnded { _ in dragOrigin = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if magnifyOrigin == nil { magnifyOrigin = navigation.zoom }
                navigation.zoom = max(0.25, min(5, (magnifyOrigin ?? zoom) * value.magnification))
            }.onEnded { _ in magnifyOrigin = nil })
            .contextMenu {
                if let target = hoveredID ?? navigation.selectedID {
                    Button(appText("Open Note")) { onOpen(target) }
                    Button(appText("Show Linked Notes Only")) { onFocus(target) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    Button { navigation.zoom = max(0.25, navigation.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { navigation.zoom = min(5, navigation.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { navigation.zoom = 1; navigation.pan = .zero } label: { Image(systemName: "arrow.counterclockwise") }
                }.buttonStyle(.borderless).padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
        }
    }
}
