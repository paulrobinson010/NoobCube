import SwiftUI

/// One side of the cube, big, to put right by hand.
///
/// Tapping a square used to step it through the colours one at a time — up to
/// five taps to get from one colour to another, with no way to see where the
/// cycle was going. Here the child picks a colour and taps the squares that
/// should be that colour, which is how a paint-by-numbers works and something
/// a five year old already knows how to do.
struct SideEditorView: View {
    @ObservedObject var coordinator: ScanCoordinator
    let face: Face

    @Environment(\.dismiss) private var dismiss
    @State private var brush: CubeColour

    init(coordinator: ScanCoordinator, face: Face) {
        self.coordinator = coordinator
        self.face = face
        _brush = State(initialValue: ScanCoordinator.colour(for: face))
    }

    /// The side drawn along the top edge of this one in the flat map, which is
    /// how it is laid out here too.
    private var sideAbove: Face {
        switch face {
        case .U: return .B
        case .D: return .F
        default: return .U
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Tap a colour, then tap the squares that should be that colour.")
                        .font(.brand(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    whichWayUp
                    grid
                        .pointedAt(.paintHere, by: coordinator.narrator)
                    palette
                        .pointedAt(.palette, by: coordinator.narrator)

                    Button {
                        coordinator.retake(face)
                        dismiss()
                    } label: {
                        Label("Take this side again", systemImage: "camera.fill")
                    }
                    .buttonStyle(BigButtonStyle(isProminent: false))
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .onAppear {
                coordinator.narrator.explain([
                    .init("Tap a colour down here,", pointingAt: .palette),
                    .init("then tap the squares that should be that colour.",
                          pointingAt: .paintHere),
                ])
            }
            .navigationTitle("The \(ScanCoordinator.colour(for: face).spokenName) side")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Which way up the side is drawn, so the squares can be matched against
    /// the cube in their hands.
    private var whichWayUp: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .black))
            chip(ScanCoordinator.colour(for: sideAbove), size: 18)
            Text("\(ScanCoordinator.colour(for: sideAbove).displayName) side at the top")
        }
        .font(.brand(size: 15, weight: .bold))
        .foregroundStyle(Theme.muted)
    }

    private var grid: some View {
        let size: CGFloat = 86
        return VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { column in
                        square(face.rawValue * 9 + row * 3 + column, size: size)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.plastic))
    }

    private func square(_ index: Int, size: CGFloat) -> some View {
        let isMiddle = index % 9 == 4
        let colour = coordinator.scan[index]
        return Button {
            coordinator.setSticker(at: index, to: brush)
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colour?.swiftUIColor ?? Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    if coordinator.doubtful.contains(index) {
                        DoubtMark(size: size)
                    } else if coordinator.justWorkedOut.contains(index) {
                        WorkedOutMark(size: size)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                           value: coordinator.justWorkedOut.contains(index))
                .overlay {
                    // The middle is not a guess: the side was asked for by it.
                    if isMiddle {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.black.opacity(0.35))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isMiddle)
        .accessibilityLabel(isMiddle ? "The middle, which cannot change"
                                     : "\(colour?.displayName ?? "Empty") square. "
                                       + "Tap to make it \(brush.spokenName)")
    }

    private var palette: some View {
        PaintPalette(brush: $brush)
    }

    private func chip(_ colour: CubeColour, size: CGFloat) -> some View {
        Circle()
            .fill(colour.swiftUIColor)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
    }
}

/// Six colours to paint with; the one picked has a ring round it.
struct PaintPalette: View {
    @Binding var brush: CubeColour

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CubeColour.allCases) { colour in
                Button {
                    brush = colour
                } label: {
                    Circle()
                        .fill(colour.swiftUIColor)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                        .padding(4)
                        .overlay(
                            Circle().strokeBorder(brush == colour ? Theme.attention : .clear,
                                                  lineWidth: 4)
                        )
                        .scaleEffect(brush == colour ? 1.1 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: brush)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paint with \(colour.spokenName)")
                .accessibilityAddTraits(brush == colour ? .isSelected : [])
            }
        }
    }
}
