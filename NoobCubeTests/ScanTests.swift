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
        // Six different centres, then eight more of each colour scattered about,
        // which is what any real cube looks like.
        var labels = [CubeColour?](repeating: nil, count: 54)
        for (position, face) in Face.allCases.enumerated() {
            labels[face.centreIndex] = CubeColour.allCases[position]
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

        let resolved = ColourClassifier.resolve(rawSamples: samples)
        XCTAssertEqual(resolved, settled)
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
