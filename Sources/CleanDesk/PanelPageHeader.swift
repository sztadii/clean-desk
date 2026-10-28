import SwiftUI

struct PanelPageHeader: View {
    let title: String
    var detail: String? = nil
    let back: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PanelPalette(colorScheme: colorScheme)
        HStack(spacing: PanelLayout.headerSpacing) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(minWidth: 76, minHeight: 38)
                .background(PanelSurface(tint: palette.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(AppRowStyle(tint: palette.accent)).fixedSize()
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .overlay {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 144)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, PanelLayout.inset).padding(.top, PanelLayout.inset)
    }
}
