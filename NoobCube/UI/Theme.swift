import SwiftUI

/// Big, bright and few words: the app is used by a five year old.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.29)
    static let background = Color(red: 0.07, green: 0.09, blue: 0.16)
    static let card = Color(red: 0.13, green: 0.16, blue: 0.25)
    static let muted = Color(red: 0.45, green: 0.48, blue: 0.56)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.45)

    static let cornerRadius: CGFloat = 22
    /// Comfortably bigger than the 44pt minimum: small fingers, moving target.
    static let minimumTapTarget: CGFloat = 64
}

extension CubeColour {
    var swiftUIColor: Color {
        let (red, green, blue) = rgb
        return Color(red: red, green: green, blue: blue)
    }
}

/// The main action on a screen. One per screen wherever possible.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(isProminent ? .white : tint)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isProminent ? tint : tint.opacity(0.16))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.card)
            )
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}
