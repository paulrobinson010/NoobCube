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
        let generation: GANProtocol.Generation
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
    /// The cube's own idea of what it looks like.
    @Published private(set) var trackedState: CubeState?

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
    /// MAC addresses picked out of advertisements, needed to build the key.
    private var macAddresses: [UUID: [UInt8]] = [:]
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
        generation = item.generation
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

    /// The MAC address sits in the last six bytes of the manufacturer data,
    /// most significant byte last.
    private static func macAddress(from manufacturerData: Data?) -> [UInt8]? {
        guard let manufacturerData, manufacturerData.count >= 6 else { return nil }
        return Array(manufacturerData.suffix(6).reversed())
    }

    // MARK: - Handling messages

    private func handle(_ raw: Data) {
        guard let cipher, let generation else { return }
        guard let decrypted = GANProtocol.decrypt(Array(raw), using: cipher) else { return }

        guard generation == .gen2 else {
            // Third and fourth generation layouts are not decoded in this build.
            status = .unsupported("This cube talks a version NoobCube can't read yet.")
            return
        }

        guard let event = GANMessageDecoder.decodeGen2(decrypted, lastSerial: lastMoveSerial) else {
            return
        }

        switch event {
        case .moves(let turns):
            for turn in turns {
                lastMoveSerial = turn.serial
                lastTurn = turn
                if let state = trackedState {
                    trackedState = state.applying(turn.move)
                }
            }
        case .facelets(_, let state):
            trackedState = state
        case .battery(let percent):
            batteryPercent = percent
        case .hardware, .unsupported:
            break
        }
    }

    /// Ask the cube to send its current state.
    private func requestState() {
        guard let peripheral, let characteristic = commandCharacteristic, let cipher else { return }
        // A "give me your facelets" request, padded to the block size.
        var command = [UInt8](repeating: 0, count: 20)
        command[0] = 0x04
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
            guard Self.looksLikeGANCube(name: name) || !advertisedServices.isEmpty else { return }

            let generation = GANProtocol.Generation.allCases.first { candidate in
                advertisedServices.contains(CBUUID(string: candidate.serviceUUID))
            } ?? .gen2

            guard Self.looksLikeGANCube(name: name) else { return }

            if let mac = Self.macAddress(from: manufacturerData) {
                self.macAddresses[peripheral.identifier] = mac
            }
            self.discoveredPeripherals[peripheral.identifier] = peripheral
            let item = Discovered(id: peripheral.identifier,
                                  name: name ?? "Smart cube",
                                  generation: generation)
            if !self.discovered.contains(item) {
                self.discovered.append(item)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let generation = self.generation else { return }
            peripheral.discoverServices([CBUUID(string: generation.serviceUUID)])
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
            guard let generation = self.generation,
                  let service = peripheral.services?.first(where: {
                      $0.uuid == CBUUID(string: generation.serviceUUID)
                  }) else {
                self.status = .unsupported("That cube doesn't look like one NoobCube knows.")
                return
            }
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

            guard let mac = self.macAddresses[peripheral.identifier],
                  let cipher = GANProtocol.cipher(generation: generation, macAddress: mac) else {
                self.status = .unsupported("NoobCube couldn't work out this cube's code.")
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
