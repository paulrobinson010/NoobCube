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
        // The six centres, then eight more of each colour scattered about,
        // which is what any real cube looks like.
        var labels = [CubeColour?](repeating: nil, count: 54)
        // The centres have to be a cube that could exist: white opposite
        // yellow and the right handedness. Six colours in whatever order they
        // happen to be declared in is not one, and the naming step is right to
        // refuse it.
        for face in Face.allCases {
            labels[face.centreIndex] = CubeColourScheme.scanningLayout[face]
        }
        var pool: [CubeColour] = []
        for colour in CubeColour.allCases {
            pool.append(contentsOf: Array(repeating: colour, count: 8))
        }
        pool.shuffle(using: &generator)
        var next = 0
        for index in 0..<54 where labels[index] == nil {
            labels[index] = pool[next]
            next += 1
        }
        let settled = labels.compactMap { $0 }

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
    func testAWholeCubeUnderTheAmberLamp() {
        var generator = SeededGenerator(seed: 17)
        let layout = CubeColourScheme.scanningLayout

        var labels = [CubeColour?](repeating: nil, count: 54)
        for face in Face.allCases { labels[face.centreIndex] = layout[face] }
        // The white side is done, so it is nine white stickers.
        for index in Face.D.faceletIndices { labels[index] = .white }

        var pool: [CubeColour] = []
        for colour in CubeColour.allCases {
            pool.append(contentsOf: Array(repeating: colour, count: colour == .white ? 0 : 8))
        }
        pool.shuffle(using: &generator)
        var next = 0
        for index in 0..<54 where labels[index] == nil {
            labels[index] = pool[next]
            next += 1
        }
        let truth = labels.compactMap { $0 }
        XCTAssertEqual(truth.count, 54)

        // Measured off the photograph: a lamp about this warm.
        let lamp = (red: 1.0, green: 0.77, blue: 0.49)
        var samples: [RGBSample] = []
        for (index, colour) in truth.enumerated() {
            let (red, green, blue) = colour.rgb
            // Each side is caught at its own angle, so each is its own brightness.
            let dim = 0.65 + 0.35 * Double((index / 9) % 3) / 2
            samples.append(RGBSample(red: min(1, red * lamp.red * dim),
                                     green: min(1, green * lamp.green * dim),
                                     blue: min(1, blue * lamp.blue * dim)))
        }

        // Without being told which side was which, this comes out wrong about
        // nineteen times in twenty — which is not something to assert on, but
        // is the measure of what knowing the middles is worth.
        XCTAssertEqual(ColourClassifier.resolve(rawSamples: samples, expectedCentres: layout),
                       truth)
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
