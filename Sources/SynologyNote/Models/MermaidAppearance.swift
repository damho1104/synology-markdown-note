enum MermaidStyle: String, CaseIterable, Identifiable {
    case classic
    case sketch = "handDrawn"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "기본"
        case .sketch: "스케치"
        }
    }
}

enum MermaidTheme: String, CaseIterable, Identifiable {
    case automatic = "system"
    case light = "default"
    case dark
    case neutral
    case forest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "화면 모드에 맞춤"
        case .light: "라이트"
        case .dark: "다크"
        case .neutral: "무채색"
        case .forest: "포레스트"
        }
    }
}
