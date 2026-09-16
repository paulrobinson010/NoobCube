import SwiftUI

/// The cube from the app icon, sitting in the corner of every screen.
///
/// Cut from the icon artwork with its edges faded out rather than cropped
/// square, so it sits straight on the background with no visible box.
struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The NoobCube lettering, lifted off the icon artwork.
struct BrandWordmark: View {
    var height: CGFloat = 46

    var body: some View {
        Image("BrandWordmark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("NoobCube")
    }
}

/// The bar across the top of every screen: the mark, where you are, and the
/// mute and repeat buttons, always in the same place.
struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    @ObservedObject var narrator: Narrator

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandMark(size: 38)

            VStack(alignment: .leading, spacing: 1) {
                if let subtitle {
                    Text(subtitle)
                        .font(.brand(size: 14, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                Text(title)
                    .font(.brand(size: 25, weight: .heavy))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)
            NarratorControls(narrator: narrator)
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        BrandWordmark(height: 56)
        BrandMark(size: 72)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
}
