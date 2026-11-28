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
            insertion: .modifier(active: Drift(opacity: 0, blur: 8, x: 0, y: 10), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.3)),
            removal: .modifier(active: Drift(opacity: 0, blur: 8, x: 0, y: -10), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.15))
        )
    }

    /// Swiping between patterns: the old name blurs away and the new one comes into focus, in place.
    static func focus(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.2)) }
        return .asymmetric(
            insertion: .modifier(active: Drift(opacity: 0, blur: 10, x: 0, y: 0), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.4).delay(0.06)),
            removal: .modifier(active: Drift(opacity: 0, blur: 10, x: 0, y: 0), identity: Drift(opacity: 1, blur: 0, x: 0, y: 0))
                .animation(.easeOut(duration: 0.2))
        )
    }
}

/// Draws text one letter at a time: each letter comes into focus from a blur, a moment after the one before.
struct LetterBlur: TextRenderer, Animatable {
    /// 0 is hidden, 1 is fully shown.
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let letters = layout.flatMap { $0 }.flatMap { $0 }
        // Each letter takes 40% of the time; starts spread across the rest.
        let spread = 0.6
        for (i, letter) in letters.enumerated() {
            let start = letters.count > 1 ? spread * Double(i) / Double(letters.count - 1) : 0
            let t = min(1, max(0, (progress - start) / (1 - spread)))
            let eased = 1 - pow(1 - t, 3)
            var copy = context
            copy.opacity = eased
            copy.addFilter(.blur(radius: 9 * (1 - eased)))
            copy.translateBy(x: 0, y: 6 * (1 - eased))
            copy.draw(letter)
        }
    }
}

private struct Letters: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.textRenderer(LetterBlur(progress: phase.isIdentity ? 1 : 0))
    }
}

extension AnyTransition {
    /// Titles: letters come into focus one after another, and leave the same way, faster.
    static func letters(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.2)) }
        return .asymmetric(
            insertion: AnyTransition(Letters()).animation(.easeOut(duration: 0.8)),
            removal: AnyTransition(Letters()).combined(with: .opacity).animation(.easeOut(duration: 0.25))
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
