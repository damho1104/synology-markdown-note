enum MermaidStyle: String, CaseIterable, Identifiable {
    case classic
    case sketch = "handDrawn"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: appText("Standard")
        case .sketch: appText("Sketch")
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
        case .automatic: appText("Match Appearance")
        case .light: appText("Light")
        case .dark: appText("Dark")
        case .neutral: appText("Neutral")
        case .forest: appText("Forest")
        }
    }
}
