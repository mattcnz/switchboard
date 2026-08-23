import SwiftUI
import CoreGraphics

enum PaletteLayout {
    static let columns = 4
    static let spacing: CGFloat = 16
    static let thumbnailWidth: CGFloat = 200
    static let thumbnailAspect: CGFloat = 0.625   // 16:10
}

struct SwitchItemCell: View, Equatable {
    let item: SwitchItem
    let cgWindowID: CGWindowID?
    let isSelected: Bool
    let previewsEnabled: Bool
    let provider: WindowThumbnailProvider

    // Per-cell state on purpose: a shared @Published dictionary would
    // invalidate every cell each time any single thumbnail arrived.
    @State private var thumbnail: NSImage?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.cgWindowID == rhs.cgWindowID
            && lhs.isSelected == rhs.isSelected
            && lhs.previewsEnabled == rhs.previewsEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnailBox
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
                Text(detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: taskKey) {
            guard previewsEnabled, let cgWindowID else { return }
            thumbnail = await provider.thumbnail(
                for: cgWindowID, width: PaletteLayout.thumbnailWidth, priority: isSelected
            )
        }
    }

    // Re-request when the window changes, or when this cell becomes selected
    // (selection jumps the capture queue).
    private var taskKey: String {
        "\(cgWindowID.map(String.init) ?? "-"):\(isSelected)"
    }

    @ViewBuilder
    private var thumbnailBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.10))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            }

            if let icon = item.icon, thumbnail != nil {
                VStack {
                    Spacer()
                    HStack {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        Spacer()
                    }
                }
                .padding(4)
            }

            if let badge = badgeText {
                VStack {
                    HStack {
                        Spacer()
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    Spacer()
                }
                .padding(4)
            }
        }
        .aspectRatio(1 / PaletteLayout.thumbnailAspect, contentMode: .fit)
        .animation(.easeOut(duration: 0.12), value: thumbnail != nil)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        )
    }

    private var badgeText: String? {
        if item.subtitle == "Minimized" { return "Minimized" }
        if item.kind == .browserTab { return "Tab" }
        return nil
    }

    private var detailText: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty, subtitle != "Minimized" {
            return "\(item.appName) — \(subtitle)"
        }
        return item.appName
    }
}
