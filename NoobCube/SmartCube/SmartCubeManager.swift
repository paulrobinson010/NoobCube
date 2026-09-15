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
    /// The cube's own idea of what it looks like, once it has been told where
    /// it is starting from. A smart cube reports turns, not colours, so this is
    /// only meaningful after ``calibrate(to:)``.
    @Published private(set) var trackedState: CubeState?

    /// Whether the tracked state can be trusted yet.
    @Published private(set) var isCalibrated = false

    /// Newer cubes number their moves relative to a position they send first,
    /// so moves arriving before that has been seen are not yet meaningful.
    private var hasSeenPosition = false

    /// What the app saw while connecting. Shown in the app so an unsupported
    /// cube can be reported with the detail needed to add support for it.
    @Published private(set) var diagnostics: [String] = []

    func note(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 40 { diagnostics.removeFirst() }
    }

    /// Tell the cube where it is starting from — normally the result of a
    /// camera scan, or the child confirming it is solved.
    func calibrate(to state: CubeState) {
        trackedState = state
        isCalibrated = true
        lastMoveSerial = nil
        note("Calibrated from a known position")
    }

    var isConnected: Bool { status.isConnected }

    /// Colours matching `trackedState`, using the cube's standard scheme.
    var trackedColours: [CubeColour?]? {
        trackedState.map { state in
            state.facelets.map { CubeColour.defaultColour(for: $0) }
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
        trackedState = nil
        isCalibrated = false
        hasSeenPosition = false
        lastMoveSerial = nil
        status = .idle
    }

    private func beginScanIfPossible() {
        guard let central, central.state == .poweredOn else { return }
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
                lastTurn = turn
                if isCalibrated, let state = trackedState {
                    trackedState = state.applying(turn.move)
                }
            }
        case .facelets(_, let state):
            hasSeenPosition = true
            // The cube counts from its own last reset, not from the colours on
            // it, so this is only believable once we have told it where it is.
            if !isCalibrated {
                trackedState = state
            }
        case .battery(let percent):
            batteryPercent = percent
        case .disconnected:
            note("Cube went to sleep")
        case .hardware, .ignored:
            break
        }
    }

    /// Ask the cube to send its current state.
    private func requestState() {
        guard let peripheral, let characteristic = commandCharacteristic, let cipher else { return }
        guard let generation else { return }
        let command = generation.requestFaceletsCommand
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
            self.trackedState = nil
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
