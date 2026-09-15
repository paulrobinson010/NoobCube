import Foundation

/// A colour sampled from the camera.
struct RGBSample: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    /// Hue in degrees, saturation and value, all 0...1 except hue.
    var hsv: (hue: Double, saturation: Double, value: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0.0001 {
            if maximum == red {
                hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
            } else if maximum == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = maximum <= 0.0001 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }
}

/// Turns camera samples into sticker colours.
///
/// Lighting on a real cube is never even — one face is always in shadow — so
/// nothing is decided on absolute colour alone. A single face is classified by
/// nearest reference for the live preview, but the scan as a whole is settled
/// by an assignment that knows there must be exactly nine of each colour. That
/// is what rescues the usual failure, orange read as red under warm light.
enum ColourClassifier {

    /// Where each colour sits, as a hue in degrees plus how saturated it is.
    private static let hueReference: [CubeColour: Double] = [
        .red: 0, .orange: 28, .yellow: 55, .green: 135, .blue: 215,
    ]

    /// Cost of calling `sample` the given colour: lower is a better match.
    static func cost(_ sample: RGBSample, as colour: CubeColour) -> Double {
        let (hue, saturation, value) = sample.hsv

        if colour == .white {
            // White is the one that is not really a hue: pale and bright.
            return saturation * 2.2 + max(0, 0.55 - value) * 1.5
        }

        // A washed-out sample is a poor fit for any of the strong colours.
        let washedOut = max(0, 0.34 - saturation) * 3.0
        guard let reference = hueReference[colour] else { return 10 }
        var difference = abs(hue - reference)
        if difference > 180 { difference = 360 - difference }
        // Red and orange sit close together, so hue distance is weighted hard.
        return difference / 45.0 + washedOut + max(0, 0.30 - value) * 1.2
    }

    /// Quick per-face guess, used while the camera is still pointing at a face.
    static func bestGuess(_ sample: RGBSample) -> CubeColour {
        CubeColour.allCases.min { cost(sample, as: $0) < cost(sample, as: $1) } ?? .white
    }

    static func bestGuesses(_ samples: [RGBSample]) -> [CubeColour] {
        samples.map(bestGuess)
    }

    /// The illuminant, estimated from the nine palest, brightest samples.
    ///
    /// A cube always has exactly nine white stickers, so they can be found
    /// without knowing which they are, and used to correct the whole scan. This
    /// is what stops warm indoor light turning every white sticker orange.
    static func whitePoint(of samples: [RGBSample]) -> RGBSample {
        let whitest = samples.sorted {
            score(whitenessOf: $0) < score(whitenessOf: $1)
        }.prefix(9)
        guard !whitest.isEmpty else { return RGBSample(red: 1, green: 1, blue: 1) }

        let count = Double(whitest.count)
        let point = RGBSample(red: whitest.reduce(0) { $0 + $1.red } / count,
                              green: whitest.reduce(0) { $0 + $1.green } / count,
                              blue: whitest.reduce(0) { $0 + $1.blue } / count)
        // Normalise so the strongest channel is 1 and nothing is scaled down.
        let strongest = max(point.red, max(point.green, point.blue))
        guard strongest > 0.001 else { return RGBSample(red: 1, green: 1, blue: 1) }
        return RGBSample(red: max(point.red / strongest, 0.001),
                         green: max(point.green / strongest, 0.001),
                         blue: max(point.blue / strongest, 0.001))
    }

    /// Lower means more likely to be one of the white stickers.
    private static func score(whitenessOf sample: RGBSample) -> Double {
        let (_, saturation, value) = sample.hsv
        return -value + saturation * 0.6
    }

    /// Divide out the illuminant, so colours can be compared to the references.
    static func whiteBalanced(_ samples: [RGBSample]) -> [RGBSample] {
        let point = whitePoint(of: samples)
        return samples.map {
            RGBSample(red: min(1, $0.red / point.red),
                      green: min(1, $0.green / point.green),
                      blue: min(1, $0.blue / point.blue))
        }
    }

    /// Settle a whole scan, given that every colour appears exactly nine times.
    ///
    /// Centres are decided first and pinned, because the six centres are always
    /// six different colours and they anchor everything else.
    static func resolve(rawSamples: [RGBSample]) -> [CubeColour] {
        precondition(rawSamples.count == 54)
        let samples = whiteBalanced(rawSamples)

        var assignment = [CubeColour?](repeating: nil, count: 54)
        var remaining: [CubeColour: Int] = [:]
        for colour in CubeColour.allCases { remaining[colour] = 9 }

        // Step one: give each centre a different colour, choosing the pairing
        // with the lowest total cost.
        let centreIndices = Face.allCases.map(\.centreIndex)
        let centreColours = assignDistinct(samples: centreIndices.map { samples[$0] })
        for (position, index) in centreIndices.enumerated() {
            let colour = centreColours[position]
            assignment[index] = colour
            remaining[colour, default: 0] -= 1
        }

        // Step two: fill the rest cheapest-first, never exceeding nine of a colour.
        var candidates: [(cost: Double, index: Int, colour: CubeColour)] = []
        for index in 0..<54 where assignment[index] == nil {
            for colour in CubeColour.allCases {
                candidates.append((cost(samples[index], as: colour), index, colour))
            }
        }
        candidates.sort { $0.cost < $1.cost }

        for candidate in candidates {
            guard assignment[candidate.index] == nil else { continue }
            guard (remaining[candidate.colour] ?? 0) > 0 else { continue }
            assignment[candidate.index] = candidate.colour
            remaining[candidate.colour, default: 0] -= 1
        }

        // Anything still unset can only be a colour with quota left.
        for index in 0..<54 where assignment[index] == nil {
            let colour = remaining.first { $0.value > 0 }?.key ?? .white
            assignment[index] = colour
            remaining[colour, default: 0] -= 1
        }
        return assignment.map { $0 ?? .white }
    }

    /// Pick six different colours for six samples, minimising total cost.
    ///
    /// Six factorial is 720, so the best pairing is simply looked up rather than
    /// approximated.
    private static func assignDistinct(samples: [RGBSample]) -> [CubeColour] {
        let colours = CubeColour.allCases
        var best: [CubeColour] = colours
        var bestCost = Double.greatestFiniteMagnitude

        permutations(of: colours) { candidate in
            var total = 0.0
            for (index, colour) in candidate.enumerated() {
                total += cost(samples[index], as: colour)
                if total >= bestCost { return }
            }
            bestCost = total
            best = candidate
        }
        return best
    }

    private static func permutations(of colours: [CubeColour],
                                     _ body: ([CubeColour]) -> Void) {
        var working = colours
        func step(_ start: Int) {
            if start == working.count { return body(working) }
            for index in start..<working.count {
                working.swapAt(start, index)
                step(start + 1)
                working.swapAt(start, index)
            }
        }
        step(0)
    }
}
