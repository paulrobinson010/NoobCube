import SwiftUI

/// The cube drawn flat, unfolded into a cross.
///
///          [ U ]
///    [ L ] [ F ] [ R ] [ B ]
///          [ D ]
///
/// Scanning fills this in live, so the child can see the cube being understood
/// one side at a time. It is anchored on the centres: yellow ends up at the top
/// and white at the bottom, because that is how they are asked to hold it.
///
/// The layout falls straight out of the facelet numbering — U is drawn with its
/// back edge at the top and D with its front edge at the top, so the squares
/// that touch on the real cube touch here too.
struct CubeNetView: View {

    var colours: [CubeColour?]
    var highlightedFace: Face? = nil
    var pulsingFace: Face? = nil
    /// Set to allow tapping a square to correct a misread colour.
    var onTapSticker: ((Int) -> Void)? = nil

    /// Where each face sits in the 4 x 3 grid of face-sized cells.
    private static let layout: [(face: Face, column: Int, row: Int)] = [
        (.U, 1, 0),
        (.L, 0, 1), (.F, 1, 1), (.R, 2, 1), (.B, 3, 1),
        (.D, 1, 2),
    ]

    private static let columns = 4
    private static let rows = 3

    var body: some View {
        GeometryReader { geometry in
            let cell = min(geometry.size.width / CGFloat(Self.columns),
                           geometry.size.height / CGFloat(Self.rows))
            let width = cell * CGFloat(Self.columns)
            let height = cell * CGFloat(Self.rows)

            ZStack(alignment: .topLeading) {
                ForEach(Self.layout, id: \.face) { entry in
                    face(entry.face, size: cell)
                        .offset(x: CGFloat(entry.column) * cell,
                                y: CGFloat(entry.row) * cell)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(CGFloat(Self.columns) / CGFloat(Self.rows), contentMode: .fit)
    }

    private func face(_ face: Face, size: CGFloat) -> some View {
        let padding = size * 0.05
        let sticker = (size - padding * 2) / 3
        let isHighlighted = highlightedFace == face
        let isPulsing = pulsingFace == face

        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                        .strokeBorder(isHighlighted ? Theme.accent : Color.white.opacity(0.12),
                                      lineWidth: isHighlighted ? 3 : 1)
                )

            ForEach(0..<9, id: \.self) { offset in
                let index = face.rawValue * 9 + offset
                let row = offset / 3
                let column = offset % 3
                stickerView(at: index, size: sticker)
                    .offset(x: padding + (CGFloat(column) - 1) * sticker,
                            y: padding + (CGFloat(row) - 1) * sticker)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(isPulsing ? 1.04 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.6).repeatCount(2, autoreverses: true),
                   value: isPulsing)
    }

    private func stickerView(at index: Int, size: CGFloat) -> some View {
        let colour = colours.indices.contains(index) ? colours[index] : nil
        let inset = size * 0.06

        return RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(colour?.swiftUIColor ?? Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .strokeBorder(Color.black.opacity(colour == nil ? 0.15 : 0.35), lineWidth: 1)
            )
            .frame(width: size - inset * 2, height: size - inset * 2)
            .contentShape(Rectangle())
            .onTapGesture { onTapSticker?(index) }
            .animation(.easeOut(duration: 0.25), value: colour)
            .accessibilityLabel(colour.map { "\($0.displayName) square" } ?? "Not seen yet")
    }
}

#Preview {
    CubeNetView(colours: ScannedCube.previewPartialScan.colours, highlightedFace: .F)
        .padding()
        .background(Theme.background)
}

extension ScannedCube {
    /// A half finished scan, for previews.
    static var previewPartialScan: ScannedCube {
        var scan = ScannedCube()
        scan.setFace(.U, to: Array(repeating: .yellow, count: 9))
        scan.setFace(.F, to: [.green, .red, .green, .blue, .green, .green, .white, .green, .orange])
        scan.setFace(.D, to: Array(repeating: .white, count: 9))
        return scan
    }
}
