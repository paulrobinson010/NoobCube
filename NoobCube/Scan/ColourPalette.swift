import Foundation

/// The six colours as this cube has actually shown them, in this room.
///
/// Naming a square against fixed references asks an impossible question: is
/// this square orange, or is it red under a warm lamp? Nothing about that one
/// square can answer it. But the scan asks for each side by name, so the middle
/// of every look is a *measured sample of a known colour* — this is what orange
/// looks like here, and this is what red looks like here. Telling the two apart
/// from each other is easy; telling either apart from an idea of orange is not.
///
/// The same goes for the pale end. A blue sticker with a lamp reflected in it
/// reads pale and washed out, which is a fine description of white, and every
/// fixed reference in the world will keep saying white. Against a blue that was
/// measured a moment ago under that same lamp, it is obviously blue.
///
/// Measured in `Tools/CubeReference/colours.py` over 500 scrambles in a spread
/// of rooms — warm lamp, daylight, dim, and each with veiling glare off the
/// plastic. The net the child watches fill in:
///
///                        squares  perfect  blue→white  yellow→orange
///     as it was            5.02%    65.4%        9.5%           7.4%
///     light guarded        3.04%    71.2%        3.7%           7.1%
///     and a palette        1.01%    90.8%        1.0%           0.6%
///
/// and the cube the scan settles on, where the pieces also have to add up,
/// went from 83.2% of scans read perfectly to 95.6%.
///
/// The palette needs all six colours before it is worth anything, so it does
/// nothing until the last side has been shown — and then every square is named
/// again. What it fixes during the scan itself is the light guard's doing.
struct ColourPalette: Equatable, Sendable {

    /// What each colour looks like here. Empty until every side has been seen.
    private(set) var reference: [CubeColour: RGBSample]

    /// How bright each colour is next to the brightest of them, which is
    /// always white. A square is only ever dark or light *compared with its
    /// neighbours*, so this is what the comparison is made against.
    private(set) var brightness: [CubeColour: Double]

    private init(reference: [CubeColour: RGBSample]) {
        self.reference = reference
        let top = reference.values.map { $0.hsv.value }.max() ?? 1
        var brightness: [CubeColour: Double] = [:]
        for (colour, sample) in reference {
            brightness[colour] = top > 0.001 ? sample.hsv.value / top : 1
        }
        self.brightness = brightness
    }

    /// Nothing measured yet: every square falls back to the fixed references.
    static let unmeasured = ColourPalette(reference: [:])

    var isEmpty: Bool { reference.isEmpty }

    /// The colours this cube has shown, from the looks taken so far.
    ///
    /// Each look's middle is the one square whose colour was known before the
    /// camera saw it, so it is taken on its own rather than averaged with its
    /// neighbours: orange and red sit about twenty degrees apart, which is
    /// close enough that averaging in "the squares that look like this one"
    /// mixes the two references together and loses the very distinction the
    /// palette exists to make.
    ///
    /// Then twice over: with six references in hand, every square goes to the
    /// nearest, and each reference is remade from the squares that chose it.
    /// A middle can be smudged, printed with a logo, or catching the light;
    /// nine or more squares agreeing are steadier than one.
    static func measured(fromLooks looks: [Face: [RGBSample]],
                         centres: [Face: CubeColour]) -> ColourPalette {
        var reference: [CubeColour: RGBSample] = [:]
        for (face, samples) in looks where samples.count == 9 {
            guard let colour = centres[face] else { continue }
            reference[colour] = samples[4]
        }
        // All six or none. A square goes to whichever colour it is nearest, so
        // a half-built palette would measure some colours and fall back to the
        // fixed references for the rest — and the two are not on the same
        // scale, so the comparison goes to whichever happened to be scored the
        // more generously. Measured side by side while scanning, that traded
        // blue read as white (3.7% of blue squares down to 2.0%) for red and
        // orange read as each other (0.2% up to 1.9%), which is no trade at
        // all. Every square is renamed once the last side lands, so nothing is
        // lost by waiting for it.
        guard reference.count == CubeColour.allCases.count else { return .unmeasured }

        var palette = ColourPalette(reference: reference)
        let squares = looks.values.flatMap { $0 }
        for _ in 0..<2 {
            var groups: [CubeColour: [RGBSample]] = [:]
            for square in squares {
                groups[palette.nearest(to: square), default: []].append(square)
            }
            for (colour, samples) in groups where samples.count >= 3 {
                reference[colour] = Self.mean(of: samples)
            }
            palette = ColourPalette(reference: reference)
        }
        return palette
    }

    /// The same thing from a whole scan's fifty-four squares.
    static func measured(from samples: [RGBSample],
                         centres: [Face: CubeColour]) -> ColourPalette {
        guard samples.count == 54 else { return .unmeasured }
        var looks: [Face: [RGBSample]] = [:]
        for face in Face.allCases {
            looks[face] = face.faceletIndices.map { samples[$0] }
        }
        return measured(fromLooks: looks, centres: centres)
    }

    // MARK: - Naming a square

    /// How far this square is from that colour, as measured.
    ///
    /// Hue carries most of the weight because veiling glare — a light source
    /// reflected off shiny plastic — adds the same grey to all three channels,
    /// which moves brightness and saturation and leaves hue exactly where it
    /// was. A pale square has no hue worth comparing, so for those the weight
    /// slides across to how pale and what tint it is.
    ///
    /// `inContextOf` is how bright this square is next to the brightest on its
    /// own side. Two squares sharing a side share a light, so which of them is
    /// darker means something even when neither one's brightness does.
    func distance(_ sample: RGBSample,
                  as colour: CubeColour,
                  inContextOf relativeBrightness: Double? = nil) -> Double {
        guard let reference = reference[colour] else {
            return ColourClassifier.cost(sample, as: colour)
        }
        let (hue, saturation, _) = sample.hsv
        let (referenceHue, referenceSaturation, _) = reference.hsv

        var gap = abs(hue - referenceHue)
        if gap > 180 { gap = 360 - gap }
        let hasHue = min(1, min(saturation, referenceSaturation) / 0.25)

        var total = gap / 45.0 * hasHue
        total += abs(saturation - referenceSaturation) * 1.6
        total += Self.tintGap(sample, reference) * 3.0
        if let relativeBrightness, let expected = brightness[colour] {
            total += abs(relativeBrightness - expected) * 2.5
        }
        return total
    }

    /// The nearest colour, ignoring how bright the square is.
    func nearest(to sample: RGBSample) -> CubeColour {
        CubeColour.allCases.min {
            distance(sample, as: $0) < distance(sample, as: $1)
        } ?? .white
    }

    /// Name all nine squares of one side together.
    ///
    /// Together rather than one at a time, because how dark a square is only
    /// means anything beside the others sharing its light. Two squares that
    /// both read somewhere between orange and red, one clearly darker than the
    /// other, are an orange and a red — and neither one alone says so.
    func names(onFace samples: [RGBSample]) -> [CubeColour] {
        guard !isEmpty else { return ColourClassifier.bestGuesses(samples) }
        let top = samples.map { $0.hsv.value }.max() ?? 1
        guard top > 0.001 else { return ColourClassifier.bestGuesses(samples) }
        return samples.map { sample in
            let relative = sample.hsv.value / top
            return CubeColour.allCases.min {
                distance(sample, as: $0, inContextOf: relative)
                    < distance(sample, as: $1, inContextOf: relative)
            } ?? .white
        }
    }

    // MARK: - Odds and ends

    /// How different two samples are in tint alone, with brightness divided
    /// out: the same colour in shadow and in sun has the same tint.
    private static func tintGap(_ first: RGBSample, _ second: RGBSample) -> Double {
        let a = tint(of: first), b = tint(of: second)
        return abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    private static func tint(of sample: RGBSample) -> (Double, Double, Double) {
        let total = sample.red + sample.green + sample.blue + 0.000001
        return (sample.red / total, sample.green / total, sample.blue / total)
    }

    private static func mean(of samples: [RGBSample]) -> RGBSample {
        let count = Double(max(samples.count, 1))
        return RGBSample(red: samples.reduce(0) { $0 + $1.red } / count,
                         green: samples.reduce(0) { $0 + $1.green } / count,
                         blue: samples.reduce(0) { $0 + $1.blue } / count)
    }
}
