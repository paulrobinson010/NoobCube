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

    // MARK: - Taking the colour of the light out

    /// A light can be warm or cold, but it is never a strong colour, so an
    /// estimate outside this range came from something that is not the light.
    private static let dimmestPlausibleChannel = 0.30

    /// The colour of the light, from one sticker whose colour we already know.
    ///
    /// Under a warm lamp a white sticker photographs cream — around hue 33 and
    /// half saturated — which is a poor white and a very good orange. That is
    /// not a fault in the maths, it is genuinely what arrived: no amount of
    /// looking at that one sticker can tell you whether it is white under an
    /// amber lamp or orange under a white one. Something outside the sticker
    /// has to break the tie, and the scan has exactly that — it asked the
    /// child for a particular side, so it knows what the middle sticker is.
    ///
    /// Dividing the light back out then puts every other sticker on the face
    /// right as well, which is what makes a mid-solve rescan work: by then the
    /// white side really is nine white stickers with nothing to compare them
    /// against.
    ///
    /// Returns nil if the answer is not a colour a light can be. That is the
    /// safety catch: if the child is showing the orange side while being asked
    /// for white, this comes out the colour of orange, which no lamp is, and
    /// the face is read as it was found instead.
    static func illuminant(from sample: RGBSample, knownToBe colour: CubeColour) -> RGBSample? {
        let (red, green, blue) = colour.rgb
        guard min(red, min(green, blue)) > 0.4 else { return nil }

        let ratio = [sample.red / red, sample.green / green, sample.blue / blue]
        guard let strongest = ratio.max(), strongest > 0.001 else { return nil }
        let normalised = ratio.map { $0 / strongest }
        guard let dimmest = normalised.min(), dimmest >= dimmestPlausibleChannel else { return nil }

        return RGBSample(red: normalised[0], green: normalised[1], blue: normalised[2])
    }

    /// The stickers on a face that look like the one at `index`.
    ///
    /// Averaging over them rather than trusting a single reading covers the
    /// logo printed on the middle of many cubes, and the glare that lands on
    /// one sticker and not its neighbour.
    private static func matching(_ index: Int, in samples: [RGBSample]) -> [RGBSample] {
        let anchor = samples[index].hsv
        return samples.filter {
            let other = $0.hsv
            var difference = abs(other.hue - anchor.hue)
            if difference > 180 { difference = 360 - difference }
            return difference < 20 && abs(other.saturation - anchor.saturation) < 0.18
        }
    }

    private static func mean(of samples: [RGBSample]) -> RGBSample {
        let count = Double(max(samples.count, 1))
        return RGBSample(red: samples.reduce(0) { $0 + $1.red } / count,
                         green: samples.reduce(0) { $0 + $1.green } / count,
                         blue: samples.reduce(0) { $0 + $1.blue } / count)
    }

    /// One face's nine readings, with the colour of the light divided out.
    ///
    /// Two ways to find that light, because each covers the other's blind spot:
    ///
    ///   * The middle sticker, when the scan knows which side it asked for.
    ///     This is the one that saves a face of nine identical whites, where
    ///     there is nothing on the face to compare anything with.
    ///   * Failing that, the palest sticker on the face — but only when it is
    ///     markedly paler than the strongest one, which is the only honest
    ///     evidence that it is a white sticker rather than simply the least
    ///     saturated of nine strong colours.
    static func illuminant(onFace samples: [RGBSample], expecting centre: CubeColour?) -> RGBSample? {
        guard samples.count == 9 else { return nil }

        if let centre, centre.rgb.red > 0.4, centre.rgb.green > 0.4, centre.rgb.blue > 0.4,
           let light = illuminant(from: mean(of: matching(4, in: samples)), knownToBe: centre) {
            return light
        }

        let saturations = samples.map { $0.hsv.saturation }
        guard let palest = saturations.min(), let strongest = saturations.max(), strongest > 0.001,
              1 - palest / strongest >= paleEnoughToBeWhite,
              let index = saturations.firstIndex(of: palest) else { return nil }
        return illuminant(from: mean(of: matching(index, in: samples)), knownToBe: .white)
    }

    /// How much paler than the strongest sticker on a face the palest one has
    /// to be before it is taken for a white one. The palest of nine strong
    /// colours is not evidence of anything.
    private static let paleEnoughToBeWhite = 0.30

    static func relit(face samples: [RGBSample], expecting centre: CubeColour?) -> [RGBSample] {
        guard let light = illuminant(onFace: samples, expecting: centre) else { return samples }
        return divide(samples, by: light)
    }

    private static func divide(_ samples: [RGBSample], by light: RGBSample) -> [RGBSample] {
        samples.map {
            RGBSample(red: min(1, $0.red / light.red),
                      green: min(1, $0.green / light.green),
                      blue: min(1, $0.blue / light.blue))
        }
    }

    /// The colour of the room, from every side that can offer an opinion.
    ///
    /// One estimate for the whole scan rather than one per side, because there
    /// is one room. Six noisy readings of the same thing, taken to the middle,
    /// are far steadier than six separate corrections — and correcting each
    /// side by its own guess turned out to be worse than not correcting at all
    /// in a dim room, because it moved the sides relative to each other. How
    /// bright each side came out is a separate matter, and ``levelled`` deals
    /// with that.
    static func illuminant(ofScan samples: [RGBSample],
                           expectedCentres: [Face: CubeColour]) -> RGBSample? {
        var lights: [RGBSample] = []
        for face in Face.allCases {
            let nine = face.faceletIndices.map { samples[$0] }
            if let light = illuminant(onFace: nine, expecting: expectedCentres[face]) {
                lights.append(light)
            }
        }
        guard !lights.isEmpty else { return nil }

        let middle = RGBSample(red: median(lights.map(\.red)),
                               green: median(lights.map(\.green)),
                               blue: median(lights.map(\.blue)))
        let strongest = max(middle.red, max(middle.green, middle.blue))
        guard strongest > 0.001 else { return nil }
        return RGBSample(red: middle.red / strongest,
                         green: middle.green / strongest,
                         blue: middle.blue / strongest)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 1 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
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

    /// Work out all 54 stickers at once, keeping only the colours.
    static func resolve(rawSamples: [RGBSample],
                        expectedCentres: [Face: CubeColour] = [:]) -> [CubeColour] {
        settle(rawSamples: rawSamples, expectedCentres: expectedCentres).colours
    }

    /// A settled reading, and how well it explains the pixels.
    struct Settled: Equatable, Sendable {
        let colours: [CubeColour]
        /// The total cost of calling every sticker what it was called. Lower is
        /// a better account of what the camera saw, and two readings of the
        /// same 54 samples can be compared by it.
        let fit: Double

        /// The same thing per sticker, which can be compared against a number
        /// rather than only against another reading of the same samples.
        var averageFit: Double { fit / 48 }
    }

    /// Above this, a reading is not worth believing.
    ///
    /// Settling now hands out whole pieces, so it always produces a cube that
    /// could exist — nine of each colour, twenty real pieces — whatever it is
    /// shown. That is the point, but it means counting stickers no longer
    /// catches a scan of the kitchen table, and a confident wrong cube is
    /// worse than no cube. How well the reading explains the pixels does
    /// catch it.
    ///
    /// Measured over random scrambles: a real cube comes in at 0.07 in good
    /// light and 0.35 in a dim amber room, where the scan is already at the
    /// edge of being any use. In 3,000 readings across five lighting
    /// conditions, not one real cube came in above this. A table top, a
    /// keyboard or a wall never came in under 1.0.
    ///
    /// Uniform random pixels — not something a camera produces, but the
    /// hardest possible thing to tell from a cube, since it has 54 different
    /// colours on it — bottomed out at 0.60 in 5,000 tries. So this is set
    /// where it refuses everything a camera realistically sees that is not a
    /// cube, and nothing that is.
    static let tooPoorToBelieve = 0.62

    /// Work out all 54 stickers at once.
    ///
    /// Three facts about cubes do most of the work, and each is worth more than
    /// any amount of tuning the colour maths:
    ///
    ///   * Every side was asked for by name, so the six middle stickers are
    ///     known before the camera sees them and are never read at all. A
    ///     middle read wrongly used to rotate the whole naming, and from there
    ///     nothing else could be right.
    ///   * The cube is made of twenty pieces, not fifty-four loose stickers.
    ///     Each edge and each corner exists exactly once, so reading one
    ///     sticker badly costs that one piece instead of cascading.
    ///   * Nine white stickers means the light can be measured off the cube
    ///     itself, without knowing which nine they are.
    ///
    /// The colour of the room is measured first and taken back out, using the
    /// one sticker on each side whose colour was known before the camera saw
    /// it. Without that, a white cube face under a warm lamp is orange, and no
    /// amount of counting stickers afterwards can tell you otherwise.
    static func settle(rawSamples: [RGBSample],
                       expectedCentres: [Face: CubeColour] = [:]) -> Settled {
        precondition(rawSamples.count == 54)
        var relitSamples = rawSamples
        if let light = illuminant(ofScan: rawSamples, expectedCentres: expectedCentres) {
            relitSamples = divide(rawSamples, by: light)
        }
        let samples = levelled(whiteBalanced(relitSamples))

        // The centres anchor everything, so take them from what the scan
        // asked for rather than from the camera. Only fall back to reading
        // them when the caller could not say.
        let naming = given(expectedCentres) ?? nameCentres(samples: samples)

        var assignment = [CubeColour?](repeating: nil, count: 54)
        for face in Face.allCases {
            assignment[face.centreIndex] = naming[face] ?? .white
        }
        var fit = fill(&assignment, slots: CubeSlots.edges, naming: naming, samples: samples)
        fit += fill(&assignment, slots: CubeSlots.corners, naming: naming, samples: samples)
        return Settled(colours: assignment.map { $0 ?? .white }, fit: fit)
    }

    /// The caller's centres, if they name all six sides of a cube that exists.
    private static func given(_ centres: [Face: CubeColour]) -> [Face: CubeColour]? {
        guard centres.count == Face.allCases.count else { return nil }
        guard CubeColourScheme.isPlausible(centres: centres) else { return nil }
        return centres
    }

    /// Hand out one set of slots — all the edges, or all the corners.
    ///
    /// Every piece the cube has is used exactly once, so a sticker read badly
    /// can only spoil the piece it is on. Cheapest fit first: each round takes
    /// the best remaining (slot, piece, way round) whose slot and piece are
    /// both still free.
    private static func fill(_ assignment: inout [CubeColour?],
                             slots: [CubeSlot],
                             naming: [Face: CubeColour],
                             samples: [RGBSample]) -> Double {
        // The pieces that exist are exactly the colours of the slots: a cube
        // has one of each, wherever it has been turned to.
        let pieces = slots.map { slot in slot.faces.map { naming[$0] ?? .white } }

        var options: [(cost: Double, slot: Int, piece: Int, colours: [CubeColour])] = []
        for (s, slot) in slots.enumerated() {
            for (p, piece) in pieces.enumerated() {
                for turn in 0..<piece.count {
                    let turned = Array(piece[turn...] + piece[..<turn])
                    let total = zip(slot.indices, turned)
                        .reduce(0.0) { $0 + cost(samples[$1.0], as: $1.1) }
                    options.append((total, s, p, turned))
                }
            }
        }
        options.sort { $0.cost < $1.cost }

        var slotTaken = [Bool](repeating: false, count: slots.count)
        var pieceTaken = [Bool](repeating: false, count: pieces.count)
        var fit = 0.0
        for option in options {
            guard !slotTaken[option.slot], !pieceTaken[option.piece] else { continue }
            slotTaken[option.slot] = true
            pieceTaken[option.piece] = true
            fit += option.cost
            for (index, colour) in zip(slots[option.slot].indices, option.colours) {
                assignment[index] = colour
            }
        }
        return fit
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
