import XCTest
@testable import NoobCube

/// "Next", "done" and "back" said instead of pressed. The microphone cannot
/// be tried here, so these pin down what happens to the words once heard.
final class VoiceCommandWordTests: XCTestCase {

    func testTheWordsThatMeanNextAndBack() {
        XCTAssertEqual(VoiceCommand.first(in: ["Next"])?.command, .next)
        XCTAssertEqual(VoiceCommand.first(in: ["done."])?.command, .next)
        XCTAssertEqual(VoiceCommand.first(in: ["necks"])?.command, .next,
                       "what a recogniser often writes for a child saying next")
        XCTAssertEqual(VoiceCommand.first(in: ["go", "back"])?.command, .back)
        XCTAssertNil(VoiceCommand.first(in: ["the", "right", "side", "up"]))
    }

    func testAWordRuledOutIsPassedOver() {
        let words = ["next", "and", "back"]
        XCTAssertEqual(VoiceCommand.first(in: words)?.at, 0)
        let after = VoiceCommand.first(in: words, skipping: [0])
        XCTAssertEqual(after?.command, .back)
        XCTAssertEqual(after?.at, 2)
    }

    func testEverySpellingOfACommandMeansIt() {
        XCTAssertTrue(VoiceCommand.next.spellings.isSuperset(of: ["next", "done", "necks"]))
        XCTAssertEqual(VoiceCommand.back.spellings, ["back"])
    }
}

@MainActor
final class VoiceCommandSessionTests: XCTestCase {

    private func session() throws -> SolveSession {
        var generator = SeededGenerator(seed: 12)
        let start = CubeState.solved.applying(randomScramble(using: &generator))
        let plan = try BeginnerSolver.solve(start)
        let scan = ScannedCube(colours: start.facelets.map { CubeColour.defaultColour(for: $0) })
        let session = SolveSession(plan: plan, scan: scan,
                                   scene: CubeSceneController(), narrator: Narrator())
        session.cubeIsFollowing = false
        session.help = .moveByMove
        session.startStage()
        return session
    }

    /// "Next" does what the Next button does: the move starts playing on
    /// screen. Nothing here runs the animation to its end, so it stays busy.
    func testNextMakesTheMove() throws {
        let session = try session()
        XCTAssertEqual(session.prompt, .tapWhenDone)
        XCTAssertNotNil(session.currentMove)
        XCTAssertTrue(session.heard(.next))
        XCTAssertTrue(session.isBusy, "the move should be under way")
        XCTAssertFalse(session.heard(.next),
                       "a second next while the first is still moving is ignored, not queued")
    }

    func testBackWithNothingToGoBackToDoesNothing() throws {
        let session = try session()
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.heard(.back))
        XCTAssertFalse(session.isBusy)
    }

    /// With a smart cube connected, turning the cube is how you say next.
    func testAConnectedCubeIgnoresNext() throws {
        let session = try session()
        session.cubeIsFollowing = true
        if session.prompt == .watching {
            XCTAssertFalse(session.heard(.next))
            XCTAssertFalse(session.heard(.back))
        }
    }

    /// Before they have said how they want to be helped, a word is not a choice.
    func testNextIsNotAChoiceOfHowToBeHelped() throws {
        let session = try session()
        session.help = .undecided
        XCTAssertFalse(session.heard(.next))
        XCTAssertEqual(session.help, .undecided)
    }
}
