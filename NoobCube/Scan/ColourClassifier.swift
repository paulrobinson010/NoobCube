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

    // MARK: - Settling a whole scan

    /// Even out the six faces before comparing them.
    ///
    /// Each side is photographed at a different moment, so one can come back
    /// noticeably darker than the next. Scaling every face to the same overall
    /// brightness stops that difference being mistaken for a difference in
    /// colour.
    static func levelled(_ samples: [RGBSample]) -> [RGBSample] {
        let values = samples.map { $0.hsv.value }.sorted()
        guard let target = values.isEmpty ? nil : values[values.count / 2], target > 0.001 else {
            return samples
        }
        var result = samples
        for face in Face.allCases {
            let range = face.faceletIndices
            let faceValues = range.map { samples[$0].hsv.value }.sorted()
            let middle = faceValues[faceValues.count / 2]
            guard middle > 0.001 else { continue }
            let scale = target / middle
            for index in range {
                result[index] = RGBSample(red: min(1, samples[index].red * scale),
                                          green: min(1, samples[index].green * scale),
                                          blue: min(1, samples[index].blue * scale))
            }
        }
        return result
    }

    /// Work out all 54 stickers at once.
    ///
    /// Three facts about cubes do most of the work, and each is worth more than
    /// any amount of tuning the colour maths:
    ///
    ///   * The centres must make a cube that could exist — white opposite
    ///     yellow, red opposite orange, blue opposite green, and in the right
    ///     handedness. That is 24 possibilities, not 720.
    ///   * There are exactly nine stickers of each colour.
    ///   * Nine white stickers means the light can be measured off the cube
    ///     itself, without knowing which nine they are.
    static func resolve(rawSamples: [RGBSample]) -> [CubeColour] {
        precondition(rawSamples.count == 54)
        let samples = levelled(whiteBalanced(rawSamples))

        // Name the centres first: they anchor everything and there are only 24
        // ways they can be arranged.
        let naming = nameCentres(samples: samples)

        var assignment = [CubeColour?](repeating: nil, count: 54)
        var remaining: [CubeColour: Int] = [:]
        for colour in CubeColour.allCases { remaining[colour] = 9 }
        for face in Face.allCases {
            let colour = naming[face] ?? .white
            assignment[face.centreIndex] = colour
            remaining[colour, default: 0] -= 1
        }

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
        for index in 0..<54 where assignment[index] == nil {
            let colour = remaining.first { $0.value > 0 }?.key ?? .white
            assignment[index] = colour
            remaining[colour, default: 0] -= 1
        }
        return assignment.map { $0 ?? .white }
    }

    /// Name the six centres, choosing among the 24 ways a cube can be held.
    static func nameCentres(samples: [RGBSample]) -> [Face: CubeColour] {
        var best = CubeColourScheme.scanningLayout
        var bestCost = Double.greatestFiniteMagnitude

        for candidate in CubeColourScheme.orientations {
            var total = 0.0
            for face in Face.allCases {
                guard let colour = candidate[face] else { continue }
                total += cost(samples[face.centreIndex], as: colour)
                if total >= bestCost { break }
            }
            if total < bestCost {
                bestCost = total
                best = candidate
            }
        }
        return best
    }
}
