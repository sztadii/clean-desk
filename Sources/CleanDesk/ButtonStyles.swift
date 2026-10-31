import AppKit
import SwiftUI

extension View {
    func pointingHand(isEnabled: Bool = true) -> some View {
        background(PointingHandRegion(isEnabled: isEnabled))
    }
}

struct AppRowStyle: ButtonStyle {
    var tint: Color = .primary
    var cornerRadius: CGFloat = PanelLayout.cornerRadius
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(RowFeedback(tint: tint, cornerRadius: cornerRadius, isPressed: configuration.isPressed, isEnabled: isEnabled))
            .background(PointingHandRegion(isEnabled: isEnabled))
    }
}

private struct RowFeedback: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let isPressed: Bool
    let isEnabled: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(tint.opacity(isEnabled ? (isPressed ? 0.13 : isHovered ? 0.065 : 0) : 0), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(isHovered && isEnabled ? 0.19 : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }
}

struct CleanDeskButtonStyle: ButtonStyle {
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CleanDeskFeedback(isPressed: configuration.isPressed, isEnabled: isEnabled, isDestructive: isDestructive))
            .background(PointingHandRegion(isEnabled: isEnabled))
    }
}

private struct CleanDeskFeedback: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    let isDestructive: Bool
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let palette = PanelPalette(colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let tint = isDestructive ? palette.danger : palette.accent
        let fill = [tint.opacity(0.16), tint.opacity(0.10)]
        content
            .foregroundStyle(isEnabled ? tint : tint.opacity(0.7))
            .background {
                shape.fill(LinearGradient(
                    colors: isEnabled ? fill : [tint.opacity(0.15), tint.opacity(0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .overlay {
                shape.fill(Color.white.opacity(isHovered && isEnabled ? 0.10 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(tint.opacity(isEnabled ? 0.22 : 0.035), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && !reduceMotion ? 0.985 : 1)
            .brightness(isPressed ? -0.035 : 0)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
    }
}

/// Let AppKit own the cursor regions so removing a hovered row, navigating
/// between views, or disabling a button cannot leave a pushed cursor behind.
private struct PointingHandRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorRegionView {
        let view = CursorRegionView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: CursorRegionView, context: Context) {
        view.showsPointingHand = isEnabled
        view.window?.invalidateCursorRects(for: view)
    }

    static func dismantleNSView(_ view: CursorRegionView, coordinator: ()) {
        view.discardCursorRects()
    }
}

private final class CursorRegionView: NSView {
    var showsPointingHand = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsPointingHand, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        addCursorRect(visibleRect, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }
}
