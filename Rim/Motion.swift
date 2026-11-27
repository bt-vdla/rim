import SwiftUI

/// Opacity, 4pt blur and a short vertical drift: in from 12pt below over 300ms, out 12pt up over 150ms.
private struct Drift: ViewModifier {
    let opacity: Double
    let blur: CGFloat
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).offset(x: x, y: y)
    }
}

extension AnyTransition {
    /// Text and content swaps. Under Reduce Motion it is a plain cross-fade.
    static func swap(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.2)) }
        return .asymmetric(
            insertion: .modifier(active: Drift(opacity: 0, blur: 4, x: 0, y: 12), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.3)),
            removal: .modifier(active: Drift(opacity: 0, blur: 4, x: 0, y: -12), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.15))
        )
    }

    /// The pattern name after a swipe: an 8pt nudge in the swipe's direction, since the finger already moved it.
    static func nudge(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let d: CGFloat = edge == .trailing ? 8 : -8
        return .asymmetric(
            insertion: .modifier(active: Drift(opacity: 0, blur: 4, x: d, y: 0), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.3)),
            removal: .modifier(active: Drift(opacity: 0, blur: 4, x: -d, y: 0), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.15))
        )
    }
}

/// A fixed design size that still follows the reader's text size.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .medium) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }
}
