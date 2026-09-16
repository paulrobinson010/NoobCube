import SwiftUI
import UIKit

/// Big, bright and few words: the app is used by a five year old.
///
/// None of these numbers are chosen here. They come from `Design/tokens.json`,
/// which the website and the cube taster on the bio site are generated from as
/// well, so the three of them are the same product rather than three things
/// with the same name. Run `Tools/sync_design.py` after changing a token.
enum Theme {
    // BEGIN generated from Design/tokens.json
    /// The button you press to get on with it.
    static let action = Color(red: 0.020, green: 0.439, blue: 0.992)

    /// Where you are now: the step you are on, the move to make next.
    static let attention = Color(red: 0.012, green: 0.922, blue: 0.996)
    /// The same colour turned down, for things that glow rather than shine.
    static let attentionGlow = Color(red: 0.004, green: 0.322, blue: 0.345)

    /// Finished, ticked off, done.
    static let done = Color(red: 0.035, green: 0.839, blue: 0.278)

    static let card = Color(red: 0.071, green: 0.125, blue: 0.220)
    static let muted = Color(red: 0.576, green: 0.655, blue: 0.741)
    static let ink = Color(red: 0.016, green: 0.063, blue: 0.110)

    /// The black a cube is made of, under the stickers.
    static let plastic = Color(red: 0.043, green: 0.063, blue: 0.094)

    static let cornerRadius: CGFloat = 22
    static let buttonDrop: CGFloat = 6
    /// How much light comes out of a button's colour for its shadow.
    static let shadowDepth: CGFloat = 0.55
    static let stickerFraction: CGFloat = 0.84
    static let stickerRadius: CGFloat = 0.22
    /// Comfortably bigger than the 44pt minimum: small fingers, moving target.
    static let minimumTapTarget: CGFloat = 64

    /// How a cube sits when nothing is happening: the same three-quarter
    /// view the website draws, so it is recognisably the same object.
    static let cubePitch: Float = -0.42
    static let cubeYaw: Float = -0.62
    // END generated

    /// The colour at the very edge of the app icon, so the launch screen and
    /// the app are the same shade and the icon dissolves into the screen.
    ///
    /// Also generated, into the asset catalog, because the launch screen is
    /// shown before any of our code runs and can only read a named colour.
    static let background = Color("LaunchBackground")
}

extension Color {
    /// The colour of this button's shadow: itself with the light taken out.
    ///
    /// The same sum the website does for `--action-shadow`, so a button looks
    /// the same in both places rather than nearly the same.
    var buttonShadow: Color { dimmed(to: Theme.shadowDepth) }

    /// This colour with the light turned down, keeping its hue.
    func dimmed(to depth: CGFloat) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return self
        }
        return Color(red: red * depth, green: green * depth, blue: blue * depth)
    }
}

extension CubeColour {
    var swiftUIColor: Color {
        let (red, green, blue) = rgb
        return Color(red: red, green: green, blue: blue)
    }
}

/// The main action on a screen. One per screen wherever possible.
///
/// The same toy button as the website's: a slab with its own shadow
/// underneath, which travels down onto it when you press. A child should be
/// able to see that it is a button without being told.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = Theme.action
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)

        return configuration.label
            .font(.brand(size: 24, weight: .bold))
            .foregroundStyle(isProminent ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            .padding(.horizontal, 20)
            .background(shape.fill(isProminent ? tint : tint.opacity(0.16)))
            .background(
                // The slab's own shadow: solid, not blurred, like a plastic toy.
                shape.fill(isProminent ? tint.buttonShadow : .clear)
                    .offset(y: Theme.buttonDrop)
            )
            .offset(y: pressed ? Theme.buttonDrop - 2 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: pressed)
    }
}

struct CardBackground: ViewModifier {
    /// The stripe along the top, as on the website's cards.
    var stripe: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(alignment: .top) {
                // Clipped to the card's corners by the shape below.
                if let stripe {
                    Rectangle().fill(stripe).frame(height: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func cardBackground(stripe: Color? = nil) -> some View {
        modifier(CardBackground(stripe: stripe))
    }
}
