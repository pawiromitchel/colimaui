import SwiftUI

/// The app's motion vocabulary, after Apple's "Designing Fluid Interfaces".
/// Springs, not fixed-duration curves: they start from the value on screen, so an interrupted
/// animation (a quick second click) redirects instead of jumping.
enum Motion {
    /// Critically damped: settles without overshoot. The default for anything that just changes state.
    static let settle = Animation.smooth(duration: 0.3)
    /// Quick, for small things like list rows and tabs.
    static let quick = Animation.smooth(duration: 0.2)
    /// A touch of bounce, for things that arrive with momentum (a toast sliding in).
    static let arrive = Animation.snappy(duration: 0.3, extraBounce: 0.1)
    /// Pointer-down feedback. Immediate and short.
    static let press = Animation.easeOut(duration: 0.1)
}

/// Pressed controls respond on pointer-down, not on release.
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A floating surface: translucent material, or a solid fill when the user asked for less transparency.
struct FloatingSurface<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay(shape.stroke(Color.primary.opacity(reduceTransparency ? 0.3 : 0.12), lineWidth: 0.5))
    }
}

extension View {
    func floatingSurface<S: Shape>(_ shape: S) -> some View { modifier(FloatingSurface(shape: shape)) }

    /// Large type reads too loose as it grows; tighten it slightly.
    func displayTracking() -> some View { tracking(-0.3) }

}

extension AnyTransition {
    /// Blur-and-scale arrival, from `anchor`. Falls back to a plain cross-fade for reduced motion.
    static func materialize(anchor: UnitPoint = .bottom, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: MaterializeEffect(active: true, anchor: anchor),
                                           identity: MaterializeEffect(active: false, anchor: anchor))
    }
}

private struct MaterializeEffect: ViewModifier {
    var active: Bool
    var anchor: UnitPoint
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
            .scaleEffect(active ? 0.94 : 1, anchor: anchor)
    }
}
