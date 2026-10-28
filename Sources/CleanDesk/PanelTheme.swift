import AppKit
import SwiftUI

struct PanelPalette {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }
    var canvas: Color {
        isDark ? Color(red: 0.095, green: 0.11, blue: 0.115)
            : Color(red: 0.965, green: 0.975, blue: 0.97)
    }
    var accent: Color {
        isDark ? Color(red: 0.49, green: 0.86, blue: 0.70)
            : Color(red: 0.12, green: 0.43, blue: 0.32)
    }
    var danger: Color {
        isDark ? Color(red: 0.98, green: 0.56, blue: 0.53)
            : Color(red: 0.70, green: 0.24, blue: 0.22)
    }
    var secondaryText: Color { Color.primary.opacity(isDark ? 0.49 : 0.55) }
    var surface: Color { isDark ? Color.white.opacity(0.025) : Color.white.opacity(0.7) }
    var hairline: Color { Color.primary.opacity(isDark ? 0.055 : 0.065) }

    static let mint = Color(red: 0.52, green: 0.90, blue: 0.74)
    static let mintDeep = Color(red: 0.32, green: 0.77, blue: 0.61)
    static let ink = Color(red: 0.055, green: 0.22, blue: 0.16)
}

struct PanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PanelPalette(colorScheme: colorScheme)
        palette.canvas
            .overlay {
                LinearGradient(colors: [palette.accent.opacity(0.055), .clear], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
    }
}

struct PanelSurface: View {
    let tint: Color
    var cornerRadius: CGFloat = PanelLayout.cornerRadius
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PanelPalette(colorScheme: colorScheme)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(palette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.085), tint.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.10 : 0.12), lineWidth: 0.5)
            }
    }
}

struct AppGlyph: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

struct CountBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(tint.opacity(0.09), in: Capsule())
    }
}

struct RowAction: View {
    let symbol: String
    let tint: Color
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(filled ? PanelPalette.ink : tint.opacity(0.9))
            .frame(width: 24, height: 24)
            .background(filled ? PanelPalette.mint : tint.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}
