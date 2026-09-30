import SwiftUI

/// A little drawn cube saying how to hold it for the side being asked for:
/// which colour faces the camera, and which is on top.
///
/// A sentence said once is easy to miss, and "now the orange side" says
/// nothing about which way up. This stays on screen the whole time the side
/// is being looked for, so a child can check against it without being told
/// twice.
struct HoldGuideView: View {
    let front: CubeColour
    let top: CubeColour?

    var body: some View {
        HStack(spacing: 10) {
            DrawnCube(front: front, top: top)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(front.displayName) towards the camera")
                if let top {
                    Text("\(top.displayName) on top")
                        .opacity(0.8)
                }
            }
            .font(.brand(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.55)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(top.map { "Hold it with \(front.spokenName) towards the camera "
                                      + "and \($0.spokenName) on top" }
                            ?? "Hold it with \(front.spokenName) towards the camera")
    }
}

/// A cube in three quarter view: the face towards you, the top, and the side.
private struct DrawnCube: View {
    let front: CubeColour
    let top: CubeColour?

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let depth = s * 0.3
            let edge = s - depth
            let outline = GraphicsContext.Shading.color(.black.opacity(0.5))

            // The side, in shadow: it is only there to make it read as a cube.
            var side = Path()
            side.move(to: CGPoint(x: edge, y: depth))
            side.addLine(to: CGPoint(x: s, y: 0))
            side.addLine(to: CGPoint(x: s, y: edge))
            side.addLine(to: CGPoint(x: edge, y: s))
            side.closeSubpath()
            context.fill(side, with: .color(Theme.plastic))
            context.stroke(side, with: outline, lineWidth: 1)

            // The top, in the colour that goes up — or plain when it does not
            // matter which way round this one is held.
            var lid = Path()
            lid.move(to: CGPoint(x: 0, y: depth))
            lid.addLine(to: CGPoint(x: depth, y: 0))
            lid.addLine(to: CGPoint(x: s, y: 0))
            lid.addLine(to: CGPoint(x: edge, y: depth))
            lid.closeSubpath()
            context.fill(lid, with: .color(top?.swiftUIColor ?? Theme.plastic))
            context.stroke(lid, with: outline, lineWidth: 1)

            // The face towards the camera, with its nine squares.
            let face = CGRect(x: 0, y: depth, width: edge, height: edge)
            context.fill(Path(face), with: .color(Theme.plastic))
            let cell = edge / 3
            for row in 0..<3 {
                for column in 0..<3 {
                    let square = CGRect(x: CGFloat(column) * cell, y: depth + CGFloat(row) * cell,
                                        width: cell, height: cell).insetBy(dx: 1, dy: 1)
                    context.fill(Path(roundedRect: square, cornerRadius: 2),
                                 with: .color(front.swiftUIColor))
                }
            }
        }
    }
}
