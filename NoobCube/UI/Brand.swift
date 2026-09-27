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
    /// Going back to the camera, where a screen offers it. Up here with the
    /// other small round buttons rather than down among the big ones: it is a
    /// way out, not somewhere to go.
    var onRescan: (() -> Void)? = nil
    /// Back to the start. Every screen past the welcome needs one, or there is
    /// no way out but force-quitting.
    var onHome: (() -> Void)? = nil

    var body: some View {
        // One row when the title fits beside the buttons, and a row of its own
        // underneath when it does not.
        //
        // It was always one row, with the title shrinking to fit — but once
        // the mark, the camera, the house and the two voice buttons have their
        // room, a phone leaves the title about a hundred points, and "Make the
        // whole yellow face" needs over three hundred. Even at its smallest it
        // was cut off, which is the one line on the screen that says what they
        // are doing.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    subtitleText
                    titleText.fixedSize()
                }
                Spacer(minLength: 4)
                buttons
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    BrandMark(size: 38)
                    subtitleText
                    Spacer(minLength: 4)
                    buttons
                }
                titleText
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.brand(size: 14, weight: .bold))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.brand(size: 25, weight: .heavy))
            .foregroundStyle(.white)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if let onRescan {
                Button(action: onRescan) {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Look at my cube again")
            }

            if let onHome {
                Button(action: onHome) {
                    Image(systemName: "house.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Back to the start")
            }

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
