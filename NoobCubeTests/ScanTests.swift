import XCTest
@testable import NoobCube

final class ScanTests: XCTestCase {

    // MARK: - Colours to solver space

    func testSolvedColoursConvertToSolvedState() throws {
        let scan = ScannedCube(colours: ScannedCube.solvedColours)
        let converted = try scan.cubeState()
        XCTAssertTrue(converted.state.isSolved)
        XCTAssertEqual(converted.whiteFace, .D)
    }

    /// The centres define the colour-to-face mapping, so it does not matter
    /// which way up the child held the cube when they scanned it.
    func testAnyOrientationConvertsAndSolves() throws {
        var generator = SeededGenerator(seed: 23)
        for rotation in ["", "y", "x", "z2", "x y", "z y2", "x2 y'"] {
            let scrambled = CubeState.solved.applying(randomScramble(using: &generator))
            // Draw the scrambled cube in real colours, then physically turn the
            // whole thing before reading it back, as if it were held differently.
            let drawn = ScannedCube(colours: scrambled.facelets.map {
                Optional(CubeColour.defaultColour(for: $0))
            }).applying(Move.parse(rotation))

            let converted = try drawn.cubeState()
            XCTAssertTrue(converted.state.isValid, "\(rotation) produced an impossible cube")

            let plan = try BeginnerSolver.solve(converted.state, whiteFace: converted.whiteFace)
            XCTAssertTrue(converted.state.applying(plan.allMoves).isSolved,
                          "held as \(rotation), the plan did not solve the cube")
        }
    }

    func testIncompleteScanIsRejected() {
        var scan = ScannedCube()
        scan.setFace(.U, to: Array(repeating: .yellow, count: 9))
        XCTAssertFalse(scan.isComplete)
        XCTAssertThrowsError(try scan.cubeState())
    }

    func testRepeatedCentreIsRejected() {
        var colours = ScannedCube.solvedColours
        colours[Face.F.centreIndex] = colours[Face.U.centreIndex]
        XCTAssertThrowsError(try ScannedCube(colours: colours).cubeState())
    }

    // MARK: - Turning a face's stickers

    func testRotatingAFaceFourTimesIsTheSame() {
        var scan = ScannedCube(colours: ScannedCube.solvedColours)
        scan[Face.U.rawValue * 9] = .red          // make the face asymmetric
        let original = scan
        scan.rotateFaceStickers(.U, quarterTurns: 4)
        XCTAssertEqual(scan, original)
    }

    func testRotatingAFaceMovesTheCorner() {
        var scan = ScannedCube(colours: ScannedCube.solvedColours)
        scan[Face.U.rawValue * 9] = .red          // top-left of U
        scan.rotateFaceStickers(.U, quarterTurns: 1)
        // A clockwise turn sends the top-left square to the top-right.
        XCTAssertEqual(scan[Face.U.rawValue * 9 + 2], .red)
        XCTAssertEqual(scan[Face.U.rawValue * 9], .yellow)
    }

    // MARK: - Colour classification

    func testReferenceColoursClassifyAsThemselves() {
        for colour in CubeColour.allCases {
            let (red, green, blue) = colour.rgb
            let sample = RGBSample(red: red, green: green, blue: blue)
            XCTAssertEqual(ColourClassifier.bestGuess(sample), colour)
        }
    }

    /// Nine of each colour, read under a warm light, must still come out right.
    /// Judging stickers one at a time gets this wrong; the whole-scan
    /// assignment plus white balance is what fixes it.
    func testWarmLightingIsRecovered() {
        var generator = SeededGenerator(seed: 41)
        // A cube that has really been turned. Nine of each colour is not
        // enough on its own: settling a scan fits whole pieces into slots, so
        // the stickers have to be arranged the way a cube can be.
        let settled = scrambledColours(using: &generator)

        let samples = settled.map { colour -> RGBSample in
            let (red, green, blue) = colour.rgb
            // Warm, slightly dim, slightly washed out.
            return RGBSample(red: min(1, red * 1.12 * 0.8),
                             green: min(1, green * 0.8),
                             blue: min(1, blue * 0.88 * 0.8))
        }

        let resolved = ColourClassifier.resolve(rawSamples: samples,
                                                expectedCentres: CubeColourScheme.scanningLayout)
        XCTAssertEqual(resolved, settled)
    }

    // MARK: - The amber lamp

    /// The nine readings below are the real thing: measured off a photograph of
    /// a white cube face taken on a phone, indoors, in the evening. They come
    /// back at hue 33 and half saturated — which is to say, orange. The whole
    /// side read as orange, so the app never recorded the white side at all and
    /// asked for it again and again.
    ///
    /// Nothing about those nine readings says white. The tie is broken from
    /// outside: the scan asked for the white side, so it knows the middle
    /// sticker is white, and that is enough to work out the colour of the lamp.
    private static let whiteSideUnderAnAmberLamp = [
        RGBSample(red: 0.957, green: 0.714, blue: 0.439),
        RGBSample(red: 0.969, green: 0.745, blue: 0.463),
        RGBSample(red: 0.988, green: 0.769, blue: 0.478),
        RGBSample(red: 0.620, green: 0.498, blue: 0.353),
        RGBSample(red: 0.608, green: 0.486, blue: 0.337),
        RGBSample(red: 0.600, green: 0.478, blue: 0.329),
        RGBSample(red: 0.957, green: 0.714, blue: 0.439),
        RGBSample(red: 0.969, green: 0.745, blue: 0.463),
        RGBSample(red: 0.988, green: 0.769, blue: 0.478),
    ]

    func testAWhiteSideUnderAnAmberLampReadsAsOrangeUntilItIsRelit() {
        let raw = ColourClassifier.bestGuesses(Self.whiteSideUnderAnAmberLamp)
        XCTAssertEqual(raw, Array(repeating: .orange, count: 9),
                       "the readings really are orange; that is the whole problem")

        let relit = ColourClassifier.relit(face: Self.whiteSideUnderAnAmberLamp,
                                           expecting: .white)
        XCTAssertEqual(ColourClassifier.bestGuesses(relit),
                       Array(repeating: .white, count: 9))
    }

    /// The safety catch. If the child shows the orange side while being asked
    /// for the white one, taking the middle sticker at its word would make the
    /// lamp the colour of orange — which no lamp is — so the face is read as it
    /// was found instead, and stays orange.
    func testShowingTheWrongSideDoesNotTurnItWhite() {
        for colour in CubeColour.allCases where colour != .white {
            let (red, green, blue) = colour.rgb
            let face = Array(repeating: RGBSample(red: red, green: green, blue: blue), count: 9)
            let relit = ColourClassifier.relit(face: face, expecting: .white)
            XCTAssertEqual(ColourClassifier.bestGuesses(relit),
                           Array(repeating: colour, count: 9),
                           "\(colour) was mistaken for white under a made-up light")
        }
    }

    /// Mid-solve the white side is nine white stickers, but at the start it is
    /// a white middle and eight of whatever else. Both have to work.
    func testAScrambledWhiteSideUnderTheSameLamp() {
        let lamp = (red: 1.0, green: 0.77, blue: 0.49)
        let truth: [CubeColour] = [.orange, .white, .green, .blue, .white, .yellow,
                                   .white, .red, .orange]
        let shade: [Double] = [1, 0.92, 1, 1, 1, 0.85, 0.7, 1, 0.8]
        let face = zip(truth, shade).map { colour, dim -> RGBSample in
            let (red, green, blue) = colour.rgb
            return RGBSample(red: min(1, red * lamp.red * dim),
                             green: min(1, green * lamp.green * dim),
                             blue: min(1, blue * lamp.blue * dim))
        }

        let relit = ColourClassifier.relit(face: face, expecting: .white)
        XCTAssertEqual(ColourClassifier.bestGuesses(relit), truth)
    }

    /// A side with a white sticker on it but no known middle: the palest
    /// sticker is the light, as long as it is much paler than the strongest.
    func testAPaleStickerStandsInForTheLight() {
        let lamp = (red: 1.0, green: 0.77, blue: 0.49)
        let truth: [CubeColour] = [.green, .white, .green, .orange, .green,
                                   .green, .yellow, .green, .blue]
        let face = truth.map { colour -> RGBSample in
            let (red, green, blue) = colour.rgb
            return RGBSample(red: min(1, red * lamp.red),
                             green: min(1, green * lamp.green),
                             blue: min(1, blue * lamp.blue))
        }

        let relit = ColourClassifier.relit(face: face, expecting: nil)
        XCTAssertEqual(ColourClassifier.bestGuesses(relit), truth)
    }

    /// And a side with no white on it at all is left exactly as it was found:
    /// the palest of nine strong colours is not evidence of anything.
    func testASideWithNoWhiteIsLeftAlone() {
        let truth: [CubeColour] = [.green, .yellow, .green, .orange, .red,
                                   .green, .yellow, .blue, .blue]
        let face = truth.map { colour -> RGBSample in
            let (red, green, blue) = colour.rgb
            return RGBSample(red: red, green: green, blue: blue)
        }
        XCTAssertEqual(ColourClassifier.relit(face: face, expecting: nil), face)
    }

    /// The whole thing end to end, in the room the screenshots were taken in,
    /// with the white side already solved — which is exactly when a child comes
    /// back for another look, and exactly when a white side has nothing on it
    /// to compare itself against.
    /// A cube that has really been turned, laid out the way the scan asks for.
    private func scrambledColours(using generator: inout SeededGenerator) -> [CubeColour] {
        let layout = CubeColourScheme.scanningLayout
        let state = CubeState.solved.applying(randomScramble(using: &generator))
        return state.facelets.map { layout[$0] ?? .white }
    }

    /// Measured off the photograph: a lamp about this warm, and each side
    /// caught at its own angle so each is its own brightness.
    private func underTheAmberLamp(_ truth: [CubeColour]) -> [RGBSample] {
        let lamp = (red: 1.0, green: 0.77, blue: 0.49)
        return truth.enumerated().map { index, colour in
            let (red, green, blue) = colour.rgb
            let dim = 0.65 + 0.35 * Double((index / 9) % 3) / 2
            return RGBSample(red: min(1, red * lamp.red * dim),
                             green: min(1, green * lamp.green * dim),
                             blue: min(1, blue * lamp.blue * dim))
        }
    }

    func testAWholeCubeUnderTheAmberLamp() {
        var generator = SeededGenerator(seed: 17)
        let truth = scrambledColours(using: &generator)

        // Without being told which side was which, this comes out wrong about
        // nineteen times in twenty — which is not something to assert on, but
        // is the measure of what knowing the middles is worth.
        XCTAssertEqual(ColourClassifier.resolve(rawSamples: underTheAmberLamp(truth),
                                                expectedCentres: CubeColourScheme.scanningLayout),
                       truth)
    }

    func testAMisreadMiddleCannotRotateTheWholeScan() {
        var generator = SeededGenerator(seed: 23)
        let layout = CubeColourScheme.scanningLayout
        let truth = scrambledColours(using: &generator)
        var samples = underTheAmberLamp(truth)

        // Paint every middle sticker the colour of the side above it. Reading
        // the middles used to mean choosing between the 24 ways a cube can be
        // held, so one bad middle turned the whole cube and nothing after it
        // could be right.
        for face in Face.allCases {
            let (red, green, blue) = (layout[face.opposite] ?? .white).rgb
            samples[face.centreIndex] = RGBSample(red: red, green: green, blue: blue)
        }

        let resolved = ColourClassifier.resolve(rawSamples: samples, expectedCentres: layout)
        for face in Face.allCases {
            XCTAssertEqual(resolved[face.centreIndex], layout[face])
        }
    }

    /// One face's nine readings, turned on the spot.
    private func turning(_ samples: [RGBSample], _ face: Face, quarterTurns: Int) -> [RGBSample] {
        var turned = samples
        for _ in 0..<quarterTurns {
            let grid = (0..<9).map { turned[face.rawValue * 9 + $0] }
            for row in 0..<3 {
                for column in 0..<3 {
                    turned[face.rawValue * 9 + row * 3 + column] = grid[(2 - column) * 3 + row]
                }
            }
        }
        return turned
    }

    func testTheTrueArrangementExplainsThePixelsBest() {
        var generator = SeededGenerator(seed: 47)
        let layout = CubeColourScheme.scanningLayout
        let truth = scrambledColours(using: &generator)
        let samples = truth.map { colour -> RGBSample in
            let (red, green, blue) = colour.rgb
            return RGBSample(red: red, green: green, blue: blue)
        }

        // Turning the top face on the spot is the mistake a child makes holding
        // the cube up to the camera. Every wrong turn costs more to believe,
        // which is what lets the scan try all four and keep the one that fits.
        let square = ColourClassifier.settle(rawSamples: samples, expectedCentres: layout)
        XCTAssertEqual(square.colours, truth)
        for quarterTurns in 1...3 {
            let turned = turning(samples, .U, quarterTurns: quarterTurns)
            XCTAssertGreaterThan(
                ColourClassifier.settle(rawSamples: turned, expectedCentres: layout).fit,
                square.fit)
        }
    }

    func testEveryReadingIsMadeOfRealPieces() {
        var generator = SeededGenerator(seed: 31)
        let layout = CubeColourScheme.scanningLayout

        for _ in 0..<50 {
            // Nonsense on purpose: whatever the camera hands over, the answer
            // has to be twenty pieces, each of them one the cube really has.
            let samples = (0..<54).map { _ in
                RGBSample(red: Double.random(in: 0...1, using: &generator),
                          green: Double.random(in: 0...1, using: &generator),
                          blue: Double.random(in: 0...1, using: &generator))
            }
            let resolved = ColourClassifier.resolve(rawSamples: samples, expectedCentres: layout)
            let scan = ScannedCube(colours: resolved.map { Optional($0) })
            let converted = try? scan.cubeState()
            XCTAssertNotNil(converted)
            guard let state = converted?.state else { continue }
            for group in [CubeSlots.edges, CubeSlots.corners] {
                let pieces = group.map { $0.piece(in: state) }
                XCTAssertEqual(Set(pieces).count, group.count)
                XCTAssertEqual(Set(pieces), Set(group.map { Set($0.faces) }))
            }
        }
    }

    // MARK: - Knowing when not to believe it

    func testSomethingThatIsNotACubeIsNotBelieved() {
        var generator = SeededGenerator(seed: 71)
        let layout = CubeColourScheme.scanningLayout

        // A real cube under the amber lamp is read badly but is still a cube,
        // and settling says so.
        let cube = ColourClassifier.settle(
            rawSamples: underTheAmberLamp(scrambledColours(using: &generator)),
            expectedCentres: layout)
        XCTAssertLessThan(cube.averageFit, ColourClassifier.tooPoorToBelieve)

        // The table the cube is sitting on is not. Settling hands out whole
        // pieces, so it will happily produce nine of each colour from this —
        // which is exactly why it has to be asked how much it believes itself.
        let table = (0..<54).map { _ in
            RGBSample(red: 0.62 + Double.random(in: -0.05...0.05, using: &generator),
                      green: 0.48 + Double.random(in: -0.05...0.05, using: &generator),
                      blue: 0.33 + Double.random(in: -0.05...0.05, using: &generator))
        }
        let notACube = ColourClassifier.settle(rawSamples: table, expectedCentres: layout)
        XCTAssertGreaterThan(notACube.averageFit, ColourClassifier.tooPoorToBelieve)
        for colour in CubeColour.allCases {
            XCTAssertEqual(notACube.colours.filter { $0 == colour }.count, 9)
        }

        // Uniform random pixels are the hardest thing to tell from a cube —
        // 54 different colours, which is what a cube is — and about one in a
        // hundred squeaks under the line. A camera does not produce them.
        var refused = 0
        for _ in 0..<20 {
            let noise = (0..<54).map { _ in
                RGBSample(red: Double.random(in: 0...1, using: &generator),
                          green: Double.random(in: 0...1, using: &generator),
                          blue: Double.random(in: 0...1, using: &generator))
            }
            if ColourClassifier.settle(rawSamples: noise, expectedCentres: layout)
                .averageFit > ColourClassifier.tooPoorToBelieve {
                refused += 1
            }
        }
        XCTAssertGreaterThanOrEqual(refused, 18)
    }

    @MainActor
    func testTheMiddlesOnTheMapCannotBeAnythingElse() {
        var generator = SeededGenerator(seed: 103)
        let layout = CubeColourScheme.scanningLayout

        // Whatever is handed to the map — a finished scan, a half one, one with
        // its middles deliberately wrong, or nothing at all — the six middles
        // come out as the grip the child was asked to use. They are not read,
        // not guessed and not editable, so there is nothing for them to be.
        for _ in 0..<50 {
            var cube = ScannedCube(colours: scrambledColours(using: &generator).map { Optional($0) })
            for face in Face.allCases {
                cube[face.centreIndex] = CubeColour.allCases.randomElement(using: &generator)
            }
            let fixed = ScanCoordinator.withFixedMiddles(cube)
            for face in Face.allCases {
                XCTAssertEqual(fixed[face.centreIndex], layout[face])
            }
        }

        let empty = ScanCoordinator.withFixedMiddles(ScannedCube())
        for face in Face.allCases {
            XCTAssertEqual(empty[face.centreIndex], layout[face])
        }
        // And they are six different colours, which is what makes the map a
        // cube at all.
        XCTAssertEqual(Set(Face.allCases.map { empty[$0.centreIndex] }).count, 6)
    }

    @MainActor
    func testALookGoesToTheSideItsMiddleNames() {
        var generator = SeededGenerator(seed: 97)
        for _ in 0..<40 {
            let truth = scrambledColours(using: &generator)
            for face in Face.allCases {
                // A cube's middles never move relative to each other, so the
                // middle sticker says which side a look is and nothing else has
                // a vote. A face with a white middle is the white side.
                XCTAssertEqual(ScanCoordinator.side(of: readings(of: truth, face: face)), face)
            }
        }
    }

    /// The real room, which is where this went wrong.
    ///
    /// `gain` dims it, `warm` tints it the colour of a lamp, and `haze` is
    /// veiling glare: every square pulled towards a bright grey, which is what
    /// a light source reflecting off shiny plastic actually does.
    private func lit(_ samples: [RGBSample],
                     warm: (Double, Double, Double) = (1, 0.88, 0.72),
                     gain: Double = 0.9,
                     haze: Double = 0) -> [RGBSample] {
        samples.map { sample in
            let channels = [sample.red * warm.0, sample.green * warm.1, sample.blue * warm.2]
                .map { min(1, $0 * gain) }
                .map { $0 * (1 - haze) + 0.92 * gain * haze }
            return RGBSample(red: channels[0], green: channels[1], blue: channels[2])
        }
    }

    /// The bug from the screenshot: a green side reported as white, over and
    /// over, so the green side never got written down.
    ///
    /// The light used to be worked out once per candidate colour, assuming that
    /// candidate — which let a candidate choose a light that made its own
    /// answer come true. Only white could do it, because only white is bright
    /// in all three channels, so on a washed-out face white scored a flat zero
    /// and won whatever the sticker really was.
    @MainActor
    func testAWashedOutSideIsStillNamedByItsMiddle() {
        var generator = SeededGenerator(seed: 5)
        let truth = scrambledColours(using: &generator)
        for haze in [0.0, 0.2, 0.35, 0.5] {
            for face in Face.allCases {
                let seen = lit(readings(of: truth, face: face), haze: haze)
                XCTAssertEqual(ScanCoordinator.side(of: seen), face,
                               "a face washed out by \(haze) should still be itself")
            }
        }
    }

    /// No candidate may fit a light that flatters its own answer: the same
    /// nine squares must cost the same whichever side is being considered.
    @MainActor
    func testNoSideGetsToChooseTheLightThatJudgesIt() {
        var generator = SeededGenerator(seed: 23)
        let truth = scrambledColours(using: &generator)
        let seen = lit(readings(of: truth, face: .F), haze: 0.4)
        let costs = Face.allCases.map { ScanCoordinator.centreCost(seen, as: $0) }
        XCTAssertEqual(costs.filter { $0 < 0.35 }.count, 1,
                       "exactly one side should be a close match, not several")
    }

    /// If every square can be read, write the side down. If one of them cannot
    /// be read at all, wait for a better moment instead of filing a guess.
    ///
    /// What this catches is a square that is not a colour: a finger over it,
    /// the edge of the cube in the crop, a sticker lost to shadow. What it
    /// cannot catch is a picture washed out evenly, because a washed-out square
    /// reads as a white sticker perfectly well — that one is caught at the end
    /// of the scan, where six sides have to add up to a cube.
    @MainActor
    func testASideIsOnlyBelievedWhenEverySquareReads() {
        var generator = SeededGenerator(seed: 41)
        let truth = scrambledColours(using: &generator)
        let clean = readings(of: truth, face: .R)

        XCTAssertTrue(ScanCoordinator.readsClearly(clean))
        XCTAssertTrue(ScanCoordinator.readsClearly(lit(clean, gain: 0.55)),
                      "a dim room is still readable")
        XCTAssertTrue(ScanCoordinator.readsClearly(lit(clean, haze: 0.3)),
                      "ordinary glare is still readable")
        XCTAssertFalse(ScanCoordinator.readsClearly([]), "nothing at all is not a side")

        // One square lost to shadow — a thumb over it, or the cube's own edge.
        var shadowed = lit(clean)
        shadowed[2] = RGBSample(red: 0.06, green: 0.05, blue: 0.07)
        XCTAssertFalse(ScanCoordinator.readsClearly(shadowed),
                       "a square that is not any colour should stop the whole side")
    }

    /// The premise of taking a side once its colours stop changing.
    ///
    /// Stability used to be measured in pixels, and that asked for frame-to-
    /// frame drift under 0.46% per channel — below the sensor's own noise.
    /// Measured against that metric, even half a percent of noise scores 0.86
    /// and fails the 0.88 it wanted, which is why a cube could sit rock steady
    /// on screen, named correctly, and never be taken.
    ///
    /// Names have no such problem. They either change or they do not.
    @MainActor
    func testTheNamedColoursSurviveNoiseThatPixelsDoNot() {
        var generator = SeededGenerator(seed: 17)
        let truth = scrambledColours(using: &generator)
        let steady = lit(readings(of: truth, face: .F))

        func naming(_ samples: [RGBSample]) -> [CubeColour] {
            ColourClassifier.bestGuesses(ColourClassifier.relit(face: samples, expecting: nil))
        }
        func jittered(by amount: Double) -> [RGBSample] {
            steady.map { sample in
                func nudge(_ value: Double) -> Double {
                    min(1, max(0, value + Double.random(in: -amount...amount, using: &generator)))
                }
                return RGBSample(red: nudge(sample.red),
                                 green: nudge(sample.green),
                                 blue: nudge(sample.blue))
            }
        }

        let wanted = naming(steady)
        XCTAssertEqual(wanted.count, 9)

        // Sensor noise, several times over: the answer must not move.
        for _ in 0..<40 {
            XCTAssertEqual(naming(jittered(by: 0.06)), wanted,
                           "ordinary noise must not change what the colours are called")
        }

        // And it must still be capable of being unsteady, or waiting for it to
        // settle would mean nothing at all.
        var seen: Set<[CubeColour]> = []
        for _ in 0..<40 { seen.insert(naming(jittered(by: 0.15))) }
        XCTAssertGreaterThan(seen.count, 1,
                             "a genuinely unstable reading should still read as unstable")
    }

    // MARK: - Taking the same side twice

    private func readings(of colours: [CubeColour], face: Face) -> [RGBSample] {
        (0..<9).map { offset in
            let (red, green, blue) = colours[face.rawValue * 9 + offset].rgb
            return RGBSample(red: red, green: green, blue: blue)
        }
    }

    @MainActor
    func testTheSamePictureAgainIsTheSameSide() {
        var generator = SeededGenerator(seed: 61)
        let truth = scrambledColours(using: &generator)
        let side = readings(of: truth, face: .F)
        // The same side a moment later: a hand shaking, not a cube turning.
        let again = side.map {
            RGBSample(red: min(1, $0.red + 0.012),
                      green: min(1, $0.green - 0.008),
                      blue: min(1, $0.blue + 0.015))
        }
        XCTAssertTrue(ScanCoordinator.looksLikeTheSameSide(side, again))
    }

    @MainActor
    func testTwoSidesOfTheSameCubeAreNotConfused() {
        var generator = SeededGenerator(seed: 67)
        var confusions = 0
        var pairs = 0
        for _ in 0..<200 {
            let truth = scrambledColours(using: &generator)
            let sides = Face.allCases.map { readings(of: truth, face: $0) }
            for first in 0..<6 {
                for second in (first + 1)..<6 {
                    pairs += 1
                    if ScanCoordinator.looksLikeTheSameSide(sides[first], sides[second]) {
                        confusions += 1
                    }
                }
            }
        }
        // Measured over 30,000 pairs of sides: one of them was close enough to
        // be called the same, and the two closest colours a cube has are
        // yellow and orange. Refusing a side is recoverable — the child turns
        // the cube and shows it again — and taking one twice is not.
        XCTAssertEqual(pairs, 3000)
        XCTAssertLessThanOrEqual(confusions, 2)
    }

    func testResolveAlwaysReturnsNineOfEach() {
        var generator = SeededGenerator(seed: 8)
        let samples = (0..<54).map { _ in
            RGBSample(red: Double.random(in: 0...1, using: &generator),
                      green: Double.random(in: 0...1, using: &generator),
                      blue: Double.random(in: 0...1, using: &generator))
        }
        let resolved = ColourClassifier.resolve(rawSamples: samples)
        for colour in CubeColour.allCases {
            XCTAssertEqual(resolved.filter { $0 == colour }.count, 9)
        }
    }
}
