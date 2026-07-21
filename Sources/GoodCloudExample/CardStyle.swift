import SwiftUI

/// A rounded, softly shadowed card surface used throughout the app for grouped content.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

/// A filled, accent-colored primary action button with a built-in disabled appearance.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isEnabled ? Theme.accent : Theme.secondaryText.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
