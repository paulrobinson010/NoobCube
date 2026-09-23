import Foundation

/// Every turn a smart cube reported, what the app made of it, and what the
/// child says they actually did.
///
/// A turn coming out as the wrong side has four places it can go wrong, and
/// the symptom looks identical from all four:
///
///   1. the number the cube sent is not the face it says it is;
///   2. ``SmartCubeDialect`` turns that number into the wrong face;
///   3. ``CubeAlignment`` renames that face wrongly for the way it is held;
///   4. the move the app asked for was never the move it drew.
///
/// Guessing between them has cost several rounds of "it still turns the
/// opposite side", so this stops guessing. Each turn is written down at every
/// stage it passes through, and then the child is asked one question — *which
/// colour did you just turn?* — which is the one piece of information the app
/// cannot get for itself. With that, the log names the culprit outright:
/// a colour that is not the face the cube reported is (1) or (2), and a colour
/// that **is** that face but not the face the app read is (3).
struct TurnLog: Equatable {

    /// One turn, from the cube's message to the child's answer.
    struct Entry: Identifiable, Equatable {
        let id: Int
        let at: Date

        /// The number the cube sent, and which way it said.
        let label: Int
        let clockwise: Bool

        /// What that number means, in the cube's own frame. Nil while the cube
        /// is still being asked what the label meant.
        var cubeMove: Move? = nil

        /// What the app called it, once the way it is being held is taken off.
        var appMove: Move? = nil

        /// The move the app had asked for, if any.
        var asked: Move? = nil

        /// The way round the cube was taken to be held, as `UDRLFF…` pairs.
        var heldAs: String? = nil

        /// How many ways of holding it were still open when this was read.
        var gripsOpen: Int? = nil

        /// What the app then did about it, in a few words.
        var outcome: String? = nil

        /// The colour the child says they turned. The only fact here that does
        /// not come from the app's own machinery.
        var turnedByHand: CubeColour? = nil

        /// The face that colour was sitting on in the picture at the time.
        var turnedFace: Face? = nil

        /// The face that colour is on the cube's *own* frame, which is fixed in
        /// its plastic and never moves.
        var turnedCubeFace: Face? {
            turnedByHand.flatMap { colour in
                Face.allCases.first { CubeColour.onTheCubesOwnFace($0) == colour }
            }
        }

        /// Where this turn went wrong, if the child has said what they did.
        var verdict: Verdict {
            guard turnedByHand != nil else { return .unanswered }
            guard let cubeMove, let cubeFace = cubeMove.base.face else { return .notRead }
            guard let saidCubeFace = turnedCubeFace else { return .unanswered }
            if cubeFace != saidCubeFace { return .cubeNamedTheWrongFace }
            guard let appMove, let appFace = appMove.base.face else { return .notRead }
            guard let shown = turnedFace else { return .cubeWasRight }
            if appFace != shown { return .heldWrongWayRound }
            return .rightAllTheWay
        }

        enum Verdict: Equatable, Hashable {
            /// The child has not said what they turned yet.
            case unanswered
            /// The app never got a move out of this at all.
            case notRead
            /// The cube's number, read through the dialect, is not the side the
            /// child turned. The fault is in the cube or the dialect.
            case cubeNamedTheWrongFace
            /// The cube was right and the app renamed it wrongly. The fault is
            /// in the alignment.
            case heldWrongWayRound
            /// The cube was right; nothing says where the picture had it.
            case cubeWasRight
            /// Right the whole way through.
            case rightAllTheWay

            var mark: String {
                switch self {
                case .unanswered:            return "?"
                case .notRead:               return "-"
                case .cubeNamedTheWrongFace: return "CUBE"
                case .heldWrongWayRound:     return "HELD"
                case .cubeWasRight:          return "ok*"
                case .rightAllTheWay:        return "ok"
                }
            }
        }
    }

    /// Something that happened to the plan rather than to the cube.
    ///
    /// A turn on its own does not say why the app then did what it did. The
    /// step changed, or the stage did, or the whole plan was thrown away and
    /// worked out again — and which of those happened, and why, is half of
    /// reading a log at all. They are numbered from the same counter as the
    /// turns, so the report can put them back in the order they happened.
    struct Moment: Identifiable, Equatable {
        let id: Int
        let at: Date
        /// What changed.
        let what: String
        /// Why it changed.
        let why: String
    }

    /// How many turns are kept. A whole solve is well under this, and the point
    /// of the log is to be read after one.
    static let kept = 200

    private(set) var entries: [Entry] = []
    private(set) var moments: [Moment] = []
    private var nextID = 1

    /// Which app face each colour is sitting on, as the picture is drawn. Set
    /// by the app, because only it knows what the plan was built from.
    var picturedAs: [CubeColour: Face] = [:]

    /// What the cube's face numbers turned out to mean, for the header.
    var dialectSaid: String = ""

    // MARK: - Writing it down

    /// A turn has arrived from the cube. Written down before anything is made
    /// of it, so a turn the app then swallows is still here to be seen.
    @discardableResult
    mutating func arrived(label: Int, clockwise: Bool) -> Int {
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, at: Date(), label: label, clockwise: clockwise))
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
        return id
    }

    /// Write down a change to the plan, and why it happened.
    mutating func happened(_ what: String, why: String) {
        let id = nextID
        nextID += 1
        moments.append(Moment(id: id, at: Date(), what: what, why: why))
        if moments.count > Self.kept { moments.removeFirst(moments.count - Self.kept) }
    }

    mutating func amend(_ id: Int, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// The newest turn the child has not yet said a colour for, and which the
    /// app has read far enough to be worth asking about.
    var waitingForAnAnswer: Entry? {
        entries.last(where: { $0.turnedByHand == nil })
    }

    mutating func theyTurned(_ colour: CubeColour, at id: Int) {
        // Read before the amending starts: reaching for it inside the closure
        // would be two overlapping accesses to the same value.
        let face = picturedAs[colour]
        amend(id) { entry in
            entry.turnedByHand = colour
            entry.turnedFace = face
        }
    }

    mutating func clear() {
        entries = []
        moments = []
        nextID = 1
    }

    /// Whether anything at all has been written down.
    var isEmpty: Bool { entries.isEmpty && moments.isEmpty }

    // MARK: - Reading it back

    var countsByVerdict: [Entry.Verdict: Int] {
        var counts: [Entry.Verdict: Int] = [:]
        for entry in entries { counts[entry.verdict, default: 0] += 1 }
        return counts
    }

    /// One line per turn, meant to be copied out and pasted somewhere.
    var report: String {
        var lines: [String] = []
        lines.append("NoobCube move log")
        if !dialectSaid.isEmpty { lines.append("what the numbers mean: \(dialectSaid)") }
        if !picturedAs.isEmpty {
            let picture = Face.allCases.compactMap { face -> String? in
                guard let colour = picturedAs.first(where: { $0.value == face })?.key
                else { return nil }
                return "\(face.letter)=\(colour.rawValue)"
            }.joined(separator: " ")
            lines.append("the picture on screen: \(picture)")
        }
        lines.append("")
        lines.append("  #  cube sent  means  app read  asked  you turned  verdict  what happened")

        // Turns and the plan's own changes, back in the order they happened.
        // Reading them apart is how "it turned the wrong side" and "it went
        // back to the start" stayed two separate mysteries: they are one
        // sequence, and a step changing between two turns is often the whole
        // explanation for the second.
        var turnNumber = 0
        var turns = entries[...]
        var changes = moments[...]
        while !turns.isEmpty || !changes.isEmpty {
            let turnID = turns.first?.id ?? Int.max
            let changeID = changes.first?.id ?? Int.max
            if turnID <= changeID, let entry = turns.first {
                turnNumber += 1
                lines.append(Self.line(turnNumber, entry))
                turns = turns.dropFirst()
            } else if let change = changes.first {
                lines.append("      -> \(change.what)  (\(change.why))")
                changes = changes.dropFirst()
            } else {
                break
            }
        }
        lines.append("")
        lines.append(contentsOf: summaryLines)
        return lines.joined(separator: "\n")
    }

    var summaryLines: [String] {
        let counts = countsByVerdict
        var lines: [String] = ["\(entries.count) turns, \(moments.count) changes to the plan"]
        let answered = entries.filter { $0.turnedByHand != nil }.count
        lines.append("\(answered) of them you said a colour for")
        if let wrong = counts[.cubeNamedTheWrongFace], wrong > 0 {
            lines.append("\(wrong) where the cube's own number was not the side you turned"
                         + "  <- the cube or the dialect")
        }
        if let held = counts[.heldWrongWayRound], held > 0 {
            lines.append("\(held) where the cube was right and the app renamed it wrongly"
                         + "  <- the way round it thinks you are holding it")
        }
        if let unread = counts[.notRead], unread > 0 {
            lines.append("\(unread) the app never got a move out of at all")
        }
        if let right = counts[.rightAllTheWay], right > 0 {
            lines.append("\(right) right the whole way through")
        }
        let ignored = entries.filter { $0.outcome == nil }.count
        if ignored > 0 { lines.append("\(ignored) that nothing was done about") }
        return lines
    }

    private static func line(_ number: Int, _ entry: Entry) -> String {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text
                : text + String(repeating: " ", count: width - text.count)
        }
        let sent = "#\(entry.label)\(entry.clockwise ? "" : "'")"
        return "  " + pad("\(number)", 3)
            + pad(sent, 11)
            + pad(entry.cubeMove?.notation ?? "-", 7)
            + pad(entry.appMove?.notation ?? "-", 10)
            + pad(entry.asked?.notation ?? "-", 7)
            + pad(entry.turnedByHand?.rawValue ?? "-", 12)
            + pad(entry.verdict.mark, 9)
            + (entry.outcome ?? "nothing")
    }
}
