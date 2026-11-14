import SwiftUI

/// Keep symbol weight and hit areas consistent across the window's controls.
struct IconButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title)
    }
}

struct SidebarItemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            configuration.title
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
