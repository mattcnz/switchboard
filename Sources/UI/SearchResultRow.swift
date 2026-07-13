import SwiftUI

struct SearchResultRow: View {
    let item: SwitchItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text(detailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(kindText)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private var detailText: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return "\(item.appName) — \(subtitle)"
        }
        return item.appName
    }

    private var kindText: String {
        switch item.kind {
        case .window: return "Window"
        case .browserTab: return "Tab"
        case .context: return ""
        }
    }
}
