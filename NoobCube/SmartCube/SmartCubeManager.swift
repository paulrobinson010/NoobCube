import Combine
@preconcurrency import CoreBluetooth
import Foundation

/// Finds and follows a GAN smart cube over Bluetooth.
///
/// When a cube is connected the app does not need the camera at all: the cube
/// says what it looks like and reports every turn as it happens, so a step can
/// tick itself off the moment the child makes the move.
///
/// The protocol is not published by GAN, so this is built on public
/// reverse-engineering and **has not been verified against real hardware in
/// this build**. Everything fails soft: an unsupported cube, a failed decrypt
/// or a nonsensical state all leave the app using the camera instead.
@MainActor
final class SmartCubeManager: NSObject, ObservableObject {

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// Only known once connected; the advertisement rarely says.
        let generation: GANProtocol.Generation?
    }

    enum Status: Equatable {
        case idle
        case bluetoothOff
        case unauthorised
        case scanning
        case connecting(String)
        case connected(String)
        case unsupported(String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var batteryPercent: Int?
    /// The most recent turn, which the app watches to advance a step.
    @Published private(set) var lastTurn: GANProtocol.Turn?

    /// What the cube says it looks like, in its own frame.
    ///
    /// The cube keeps this itself, from its own last reset, and every turn it
    /// reports is applied here as it arrives. It is shown as soon as there is
    /// one: a child who has just connected a cube wants to see their cube, not
    /// be asked to solve it first.
    @Published private(set) var cubeState: CubeState?

    /// The ways round the cube could be being held.
    ///
    /// One once it is known, and until then every way that is still possible.
    /// The cube's "R" is whichever side of it happens to be on the right, and
    /// nothing says that is the side the child is calling right — but the app
    /// knows which move it asked for, so each turn rules out the ways of
    /// holding it that would have made the turn something else.
    @Published private(set) var grips: [CubeAlignment] = []

    /// The grip, once there is only one left it could be.
    var alignment: CubeAlignment? { grips.count == 1 ? grips[0] : nil }

    /// Whether the cube is worth listening to at all. It is, long before the
    /// grip is settled: a turn every candidate reads the same way is a turn we
    /// can act on.
    var isFollowing: Bool { isConnected && !grips.isEmpty && cubeState != nil }

    /// Whether the grip is still being worked out from the turns.
    var isStillWorkingOutTheGrip: Bool { grips.count > 1 }

    /// Whether the cube's own position is worth planning a solve from.
    ///
    /// Only after the camera has put it right, or the child has said it is
    /// solved. A cube whose position disagreed with the scan keeps reporting
    /// turns perfectly well — which is enough to follow along — but its idea of
    /// where it *is* remains wrong, and a plan built on that would be wrong too.
    @Published private(set) var positionIsTrustworthy = false

    /// Whether the cube has said what it looks like yet.
    var hasSaidWhatItLooksLike: Bool { cubeState != nil }

    /// Newer cubes number their moves relative to a position they send first,
    /// so moves arriving before that has been seen are not yet meaningful.
    private var hasSeenPosition = false

    /// What the app saw while connecting. Shown in the app so an unsupported
    /// cube can be reported with the detail needed to add support for it.
    @Published private(set) var diagnostics: [String] = []

    /// What the cube said and what the app made of it. Kept for a console
    /// during development rather than shown to anyone: a parent has no use for
    /// it, and a child less.
    /// Everything about one turn, in one line.
    ///
    /// A turn coming out as the wrong face has four places it can go wrong —
    /// the number the cube sent, what that number means, which way round the
    /// cube is being held, and what the app was expecting — and describing the
    /// symptom cannot tell them apart. This can.
    func noteTurn(_ said: Move, readAs ours: Move, whenAskedFor asked: Move?) {
        let label = lastTurn.map { "#\($0.label)\($0.clockwise ? "" : "'")" } ?? "#?"
        let held = alignment.map { grip in
            grip.appFace.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.letter)\($0.value.letter)" }.joined()
        } ?? "\(grips.count) still possible"
        note("turn \(label) -> \(said.notation) -> \(ours.notation)"
             + "   asked \(asked?.notation ?? "-")   held \(held)"
             + "   sensor \(sensorGrip == nil ? "no" : "yes")")
    }

    func note(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 40 { diagnostics.removeFirst() }
        #if DEBUG
        print("NoobCube smart cube: \(line)")
        #endif
    }

    /// Work out which way round the cube is being held, by holding what it
    /// says it looks like against what the camera saw.
    /// Returns nil when the cube has not said where it is yet, which is not the
    /// same as disagreeing and must not be reported as though it were.
    @discardableResult
    func align(toScan scanned: CubeState,
               middles: [Face: CubeColour]) -> CubeAlignment.Match? {
        guard cubeState != nil else {
            note("No position from the cube yet, so nothing to line up against")
            grips = []
            return nil
        }

        // Off the middles, which never move. Where the cube's pieces have got
        // to has no bearing on which of its faces is the red one, so this works
        // whether or not the cube's own idea of itself is right — and a cube
        // whose idea of itself is wrong is precisely why the camera was reached
        // for.
        if let held = CubeAlignment.matching(centresSeen: middles) {
            grips = [held]
            cubeState = held.cubeState(of: scanned)
            positionIsTrustworthy = true
            calibrateOrientation(against: held)
            note("Lined up off the middles: " + held.appFace
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.letter)->\($0.value.letter)" }
                    .joined(separator: " "))
            return .found(held)
        }

        // Only if the camera could not name all six middles. Then there is
        // nothing certain to go on and the turns have to settle it.
        note("The camera did not name all six middles, so the turns will settle it")
        return alignByPosition(scanned)
    }

    /// The old way: line the cube's own position up against the scan.
    ///
    /// Kept for a scan that could not name every middle. It cannot tell a cube
    /// whose position has drifted from one that is being held differently, so
    /// it is the fallback rather than the method.
    private func alignByPosition(_ scanned: CubeState) -> CubeAlignment.Match? {
        guard let cubeState else { return nil }
        let match = CubeAlignment.matching(cube: cubeState, scanned: scanned)
        grips = CubeAlignment.possibilities(cube: cubeState, scanned: scanned)
        switch match {
        case .found(let found):
            // The camera has just seen the cube as it really is, so whatever
            // the cube believed is replaced rather than merely agreed with.
            // Nothing can drift apart again from here.
            self.cubeState = found.cubeState(of: scanned)
            positionIsTrustworthy = true
            calibrateOrientation(against: found)
            note("Lined up with the scan: " + found.appFace
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.letter)->\($0.value.letter)" }
                    .joined(separator: " "))
        case .tooSymmetricToTell:
            positionIsTrustworthy = true
            note("Cube looks the same every way round, so any grip will do")
        case .cubeDisagrees:
            positionIsTrustworthy = false
            // Not a dead end any more. Its turns are still good, so the grip
            // gets worked out from them over the next move or two.
            note("The cube's own position does not match the scan — "
                 + "working the grip out from your turns instead")
        }
        return match
    }

    /// Take this grip as the one everything is now counted from.
    ///
    /// Used when the plan is worked out afresh: the new plan starts from the
    /// cube exactly as it is being held, so the whole-cube turns the old plan
    /// had already made are spent and must not be counted a second time.
    func reground(to alignment: CubeAlignment) {
        grips = [alignment]
        positionIsTrustworthy = true
    }

    /// Every way the cube could be being held, with nothing ruled out.
    ///
    /// This is what "we do not know yet" looks like, and it is the only honest
    /// thing to say before a turn has been seen. A cube reports its turns in
    /// its own frame, and how that frame sits in a child's hands is not
    /// something the cube can tell you — only the turns can, and they settle it
    /// after two of them.
    func openEveryGrip(trustingPosition: Bool = false) {
        // The way they were asked to hold it comes first, so a turn read before
        // anything has narrowed the set is read that way rather than as though
        // the cube's own frame were the child's — see
        // ``CubeAlignment/likeliestFirst(_:)``.
        grips = CubeAlignment.likeliestFirst(
            CubeAlignment.allGrips.map { CubeAlignment.identity.regripped(by: $0) })
        if trustingPosition { positionIsTrustworthy = true }
    }

    /// Throw the grip away and work it out again from the turns.
    ///
    /// For when the grip we settled on keeps disagreeing with what the child is
    /// actually doing. A grip derived from a cube's own position is only as
    /// good as that position, and if it turns out to be wrong there is no
    /// reason to keep believing it — the turns themselves are better evidence,
    /// and they are what settled it in the first place.
    func reopenTheGrip() {
        guard grips.count == 1 else { return }
        openEveryGrip()
        note("That grip kept being wrong — working it out from your turns again")
    }

    /// Rule out the ways of holding the cube that a turn has just disproved.
    func narrow(to remaining: [CubeAlignment]) {
        guard !remaining.isEmpty, remaining.count < grips.count else { return }
        grips = remaining
        if remaining.count == 1 {
            calibrateOrientation(against: remaining[0])
            note("Grip settled from your turns: " + remaining[0].appFace
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.letter)->\($0.value.letter)" }
                    .joined(separator: " "))
        }
    }

    /// The child says the cube is solved right now. The only position a cube
    /// can be told about without looking at it, and the way back when its own
    /// idea of itself has drifted.
    func startFromSolved() {
        cubeState = .solved
        // Where it is, yes. Which way round it is being held, no — and a solved
        // cube is the one position from which that can never be read, because
        // it looks exactly the same all twenty-four ways round. Saying
        // "identity" here is a one-in-twenty-four guess dressed up as a fact,
        // and because it leaves a single settled grip the app stops learning
        // and starts telling the child they turned the wrong side instead.
        openEveryGrip()
        positionIsTrustworthy = true
        lastMoveSerial = nil
        note("Told it is solved right now; which way round it is held is still open")
    }

    var isConnected: Bool { status.isConnected }

    /// A battery reading worth showing, or nothing.
    ///
    /// A cube that is awake and talking to us is not flat, so a reading of 0 —
    /// or of anything above 100 — is not a flat battery. It is the wrong bits
    /// being read, and showing it as fact is worse than showing nothing at all.
    /// The raw number goes to the diagnostics instead, which is what is needed
    /// to put the offsets right.
    static func believableBattery(_ percent: Int) -> Int? {
        (1...100).contains(percent) ? percent : nil
    }

    /// Colours matching `cubeState`, laid out the way the child is asked to
    /// hold the cube — yellow on top — rather than the way the cube numbers
    /// its own faces. They are half a turn apart, and the one worth showing is
    /// the one they can hold up against what is in their hands.
    var trackedColours: [CubeColour?]? {
        cubeState.map { state in
            CubeAlignment.asTheChildIsAskedToHoldIt.appState(of: state)
                .facelets.map { CubeColour.defaultColour(for: $0) }
        }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var generation: GANProtocol.Generation?
    private var cipher: GANProtocol.Cipher?
    private var commandCharacteristic: CBCharacteristic?
    private var lastMoveSerial: Int?
    /// Key salts picked out of advertisements, needed to build the cipher.
    private var salts: [UUID: [UInt8]] = [:]
    /// CoreBluetooth drops peripherals it is not holding on to, so they are kept here.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Scanning and connecting

    func startScanning() {
        // Already connected: there is nothing to look for, and looking anyway
        // used to overwrite "Connected to your cube" with "Looking for cubes"
        // and leave it there. Coming back to this screen is not a reason to
        // forget the cube in your hand.
        guard !isConnected else { return }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfPossible()
        }
    }

    func stopScanning() {
        central?.stopScan()
        if case .scanning = status { status = .idle }
    }

    func connect(_ item: Discovered) {
        guard let central,
              let found = discoveredPeripherals[item.id]
                  ?? central.retrievePeripherals(withIdentifiers: [item.id]).first else {
            status = .failed("Couldn't find that cube again.")
            return
        }
        central.stopScan()
        peripheral = found
        found.delegate = self
        status = .connecting(item.name)
        central.connect(found)
    }

    func disconnect() {
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        cipher = nil
        generation = nil
        cubeState = nil
        grips = []
        positionIsTrustworthy = false
        hasSeenPosition = false
        lastMoveSerial = nil
        forgetTheDialect()
        status = .idle
    }

    /// What a cube's labels mean belongs to that cube's firmware, so it is kept
    /// for as long as the cube is connected and thrown away when it is not.
    private func forgetTheDialect() {
        dialect = .asTheseCubesNumberThem
        lastRawTurn = nil
        orientation.forget()
        lastQuaternion = nil
        sensorGrip = nil
        turnsAwaitingTheirMeaning = []
        positionBeforeThem = nil
        lastMove = nil
    }

    private func beginScanIfPossible() {
        guard let central, central.state == .poweredOn, !isConnected else { return }
        discovered.removeAll()
        status = .scanning
        // GAN cubes do not always advertise their service UUID, so everything
        // nearby is looked at and filtered by name.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private static func looksLikeGANCube(name: String?) -> Bool {
        guard let name else { return false }
        let upper = name.uppercased()
        return upper.hasPrefix("GAN") || upper.hasPrefix("MG") || upper.hasPrefix("AICUBE")
    }

    /// The key salt: the last six bytes of the advertised maker data, in the
    /// order they arrive.
    ///
    /// That data holds the cube's MAC address backwards, and the salt is the
    /// MAC reversed again — so the two reversals cancel and the bytes are used
    /// as they come.
    private static func salt(from manufacturerData: Data?) -> [UInt8]? {
        guard let manufacturerData, manufacturerData.count >= 6 else { return nil }
        return Array(manufacturerData.suffix(6))
    }

    // MARK: - Handling messages

    private func handle(_ raw: Data) {
        guard let cipher, let generation else { return }
        guard let decrypted = GANProtocol.decrypt(Array(raw), using: cipher) else { return }

        guard let event = GANMessageDecoder.decode(decrypted,
                                                   generation: generation,
                                                   lastSerial: lastMoveSerial) else {
            return
        }

        switch event {
        case .moves(let turns):
            guard hasSeenPosition || generation == .gen2 else { return }
            for turn in turns {
                lastMoveSerial = turn.serial
                received(turn)
            }
        case .facelets(_, let state):
            hasSeenPosition = true
            positionArrived(state)
        case .orientation(let quaternion):
            orientationArrived(quaternion)
        case .battery(let percent):
            batteryPercent = Self.believableBattery(percent)
            if batteryPercent == nil {
                note("Battery read as \(percent), which cannot be right — ignoring it")
            }
        case .disconnected:
            note("Cube went to sleep")
        case .hardware, .ignored:
            break
        }
    }

    /// Ask the cube how full its battery is.
    ///
    /// Most of these cubes only say when asked. Nothing here ever asked, so the
    /// only readings that ever arrived were unsolicited ones — which is how a
    /// cube with plenty of charge came to show 0%.
    ///
    /// The request follows the shape already established for asking a cube its
    /// position: the same envelope with the event code swapped. That holds for
    /// the two generations whose position request carries its event code, and
    /// is not guessed at for the one that does not.
    private func requestBattery() {
        guard let generation, let command = generation.requestBatteryCommand else { return }
        send(command)
    }

    // MARK: - Which way up it is

    /// The cube's own sense of which way up it is.
    ///
    /// Its face numbers are welded to the plastic, so the position it reports
    /// is right however the child holds it — that never needed a grip and never
    /// will. What needed one is *talking* about it: "turn the right-hand side"
    /// means knowing which side is on their right. The motion sensor answers
    /// that outright, and keeps answering it while the cube is turned about.
    private var orientation = CubeOrientation()
    private var lastQuaternion: CubeOrientation.Quaternion?

    /// How the cube is being held, according to its motion sensor.
    ///
    /// Nil until the sensor has been pinned against a grip worked out some
    /// other way — from a scan, or from the turns settling it. Until then the
    /// app has no business having an opinion, and the old way of guessing one
    /// is what spent four rounds telling a child they turned the wrong side.
    @Published private(set) var sensorGrip: CubeAlignment?

    var knowsHowItIsHeld: Bool { sensorGrip != nil }

    private func orientationArrived(_ quaternion: CubeOrientation.Quaternion) {
        lastQuaternion = quaternion
        guard orientation.isCalibrated else { return }
        let held = orientation.grip(sensor: quaternion)
        if held != sensorGrip {
            sensorGrip = held
            if let held, grips.count > 1 {
                // The sensor knows, so there is nothing left to work out.
                grips = [held]
                note("Held as " + held.appFace
                        .sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.letter)->\($0.value.letter)" }
                        .joined(separator: " ") + " (from the cube's own sensor)")
            }
        }
    }

    /// Pin the sensor's frame to the child's, from a moment the grip is known.
    ///
    /// GAN's axes never have to be known: the two frames differ by one fixed
    /// rotation, and this is where it is measured. Everything after cancels.
    private func calibrateOrientation(against grip: CubeAlignment) {
        guard let lastQuaternion else { return }
        orientation.calibrate(sensor: lastQuaternion, isBeingHeldAs: grip)
        sensorGrip = orientation.grip(sensor: lastQuaternion)
        if orientation.isCalibrated {
            note("Motion sensor lined up; which way up it is no longer has to be guessed")
        }
    }

    // MARK: - Reading a turn

    /// What this cube's own words for its faces turned out to mean.
    private(set) var dialect = SmartCubeDialect.asTheseCubesNumberThem

    /// Turns whose label the cube has not been asked about yet.
    ///
    /// Held rather than guessed at. The cube is asked where it is, and the
    /// answer says both what the turn was and what the label meant, for good.
    /// One question per label, and a whole solve only ever turns five faces.
    private var turnsAwaitingTheirMeaning: [GANProtocol.Turn] = []

    /// Where the cube was before the first of those.
    private var positionBeforeThem: CubeState?

    /// The move the app made of the last turn, once the cube's own word for it
    /// has been translated. This is what the rest of the app listens to: what
    /// the cube calls its faces is nobody else's business.
    @Published private(set) var lastMove: Move?

    /// Every turn exactly as the cube sent it, before the app makes anything
    /// of it. The turn check listens to this; everything else wants the move.
    @Published private(set) var lastRawTurn: GANProtocol.Turn?

    private func received(_ turn: GANProtocol.Turn) {
        lastRawTurn = turn
        if let move = dialect.move(forLabel: turn.label, clockwise: turn.clockwise) {
            return act(on: turn, as: move)
        }
        guard let here = cubeState else {
            // Nowhere to measure from. The cube is asked on connecting, so this
            // is a message arriving before the answer — ask again rather than
            // name the turn from a table nothing has checked.
            requestState()
            return
        }
        if turnsAwaitingTheirMeaning.isEmpty {
            positionBeforeThem = here
        }
        turnsAwaitingTheirMeaning.append(turn)
        requestState()
    }

    private func act(on turn: GANProtocol.Turn, as move: Move) {
        // Keep the cube's own position up to date before saying a turn
        // happened, so anything reacting to the turn sees the cube as it is
        // now rather than as it was a move ago.
        if let state = cubeState {
            cubeState = state.applying(move)
        }
        lastTurn = turn
        lastMove = move
    }

    private func positionArrived(_ state: CubeState) {
        guard !turnsAwaitingTheirMeaning.isEmpty else {
            // Nothing outstanding, so this is the cube saying where it is. A
            // position the cube reports is better evidence than a tally built
            // on top of one, and disagreeing with it quietly is exactly what
            // let a misread turn go unnoticed for a whole solve.
            if cubeState == nil || grips.isEmpty {
                cubeState = state
            } else if cubeState != state {
                note("Cube says it is somewhere else; taking its word for it")
                cubeState = state
            }
            return
        }

        let waiting = turnsAwaitingTheirMeaning
        let before = positionBeforeThem
        turnsAwaitingTheirMeaning = []
        positionBeforeThem = nil

        // One turn between the two positions is the case worth having: the move
        // is then exactly determined, and with it what the cube's word for that
        // face means. More than one and this says nothing about any of them.
        if waiting.count == 1, let before, let move = Move.between(before, and: state) {
            let turn = waiting[0]
            dialect.learn(label: turn.label, clockwise: turn.clockwise, was: move)
            note("Cube's face \(turn.label)\(turn.clockwise ? "" : " reversed")"
                 + " turned out to be \(move.notation)")
            cubeState = before
            return act(on: turn, as: move)
        }

        // Too much happened at once to learn anything from it. Take the cube's
        // own position — it is still the truth — and say nothing about the
        // turns rather than name them from a table that has never been checked.
        // The next turn on that face will be asked about again.
        cubeState = state
        note("\(waiting.count) turns arrived before the cube said where it was; "
             + "nothing learned from them")
    }

    /// Ask the cube to send its current state.
    private func requestState() {
        guard let generation else { return }
        send(generation.requestFaceletsCommand)
    }

    private func send(_ command: [UInt8]) {
        guard let peripheral, let characteristic = commandCharacteristic, let cipher else { return }
        guard let encrypted = GANProtocol.encrypt(command, using: cipher) else { return }
        peripheral.writeValue(Data(encrypted), for: characteristic, type: .withResponse)
    }
}

// MARK: - CoreBluetooth

extension SmartCubeManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: self.beginScanIfPossible()
            case .poweredOff: self.status = .bluetoothOff
            case .unauthorized: self.status = .unauthorised
            default: self.status = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        Task { @MainActor in
            guard Self.looksLikeGANCube(name: name) else { return }

            // Which generation this is cannot be told from the advertisement:
            // most cubes do not list their service there. It is settled after
            // connecting, by looking at what the cube actually has.
            let advertised = GANProtocol.Generation.allCases.first { candidate in
                advertisedServices.contains(CBUUID(string: candidate.serviceUUID))
            }

            if let salt = Self.salt(from: manufacturerData) {
                self.salts[peripheral.identifier] = salt
            }
            self.discoveredPeripherals[peripheral.identifier] = peripheral
            self.note("Found \(name ?? "a cube")")
            if let manufacturerData {
                self.note("  maker data: \(manufacturerData.map { String(format: "%02x", $0) }.joined(separator: " "))")
            } else {
                self.note("  no maker data in the advert")
            }

            let item = Discovered(id: peripheral.identifier,
                                  name: name ?? "Smart cube",
                                  generation: advertised)
            if !self.discovered.contains(item) {
                self.discovered.append(item)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Ask for everything. Narrowing the search to a guessed generation
            // is what made a perfectly good cube report itself unsupported.
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.status = .failed(error?.localizedDescription ?? "Couldn't connect to the cube.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.cubeState = nil
            self.grips = []
            self.positionIsTrustworthy = false
            self.forgetTheDialect()
            self.status = .idle
        }
    }
}

extension SmartCubeManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            let services = peripheral.services ?? []
            for service in services {
                self.note("  service \(service.uuid.uuidString)")
            }

            let match = GANProtocol.Generation.allCases.compactMap {
                generation -> (GANProtocol.Generation, CBService)? in
                guard let service = services.first(where: {
                    $0.uuid == CBUUID(string: generation.serviceUUID)
                }) else { return nil }
                return (generation, service)
            }.first

            guard let (generation, service) = match else {
                // Report what the cube actually has rather than a shrug: these
                // identifiers are what a new generation needs adding from.
                let found = services.map(\.uuid.uuidString).joined(separator: ", ")
                self.status = .unsupported(found.isEmpty
                    ? "That cube didn't tell me what it can do."
                    : "NoobCube doesn't know this cube's language yet.")
                self.note(found.isEmpty ? "  no services found" : "  no known service among those")
                return
            }

            self.generation = generation
            self.note("  matched \(generation.rawValue)")
            peripheral.discoverCharacteristics([
                CBUUID(string: generation.stateCharacteristicUUID),
                CBUUID(string: generation.commandCharacteristicUUID),
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard let generation = self.generation else { return }

            guard let salt = self.salts[peripheral.identifier],
                  let cipher = GANProtocol.cipher(generation: generation, salt: salt) else {
                self.status = .unsupported("NoobCube couldn't work out this cube's code. "
                                         + "Its advert didn't include the number needed.")
                self.note("  no salt: the advert carried no maker data")
                return
            }
            self.cipher = cipher

            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == CBUUID(string: generation.stateCharacteristicUUID) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if characteristic.uuid == CBUUID(string: generation.commandCharacteristicUUID) {
                    self.commandCharacteristic = characteristic
                }
            }
            self.status = .connected(peripheral.name ?? "Smart cube")
            self.requestState()
            self.requestBattery()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        Task { @MainActor in
            self.handle(value)
        }
    }
}
