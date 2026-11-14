import Foundation

public enum NoteSortField: String, CaseIterable, Sendable {
    case title, createdAt, modifiedAt
}

public enum NoteSortDirection: String, CaseIterable, Sendable {
    case ascending, descending
}

/// Sorts the visible summaries without changing their stored or NAS order.
public struct NoteListSort: Sendable {
    public let field: NoteSortField
    public let direction: NoteSortDirection

    public init(field: NoteSortField = .modifiedAt, direction: NoteSortDirection = .descending) {
        self.field = field
        self.direction = direction
    }

    public func sorted(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.sorted { left, right in
            let comparison: ComparisonResult
            switch field {
            case .title:
                comparison = left.title.localizedStandardCompare(right.title)
            case .createdAt:
                comparison = Self.compare(left.createdAt ?? left.modifiedAt, right.createdAt ?? right.modifiedAt)
            case .modifiedAt:
                comparison = Self.compare(left.modifiedAt, right.modifiedAt)
            }
            if comparison != .orderedSame {
                return comparison == (direction == .ascending ? .orderedAscending : .orderedDescending)
            }
            // Stable ordering even when several notes share a timestamp or title.
            let titles = left.title.localizedStandardCompare(right.title)
            if titles != .orderedSame { return titles == .orderedAscending }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private static func compare(_ left: Date, _ right: Date) -> ComparisonResult {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }
}
