import Foundation

/// Turns a decrypted GAN message into something the app understands.
///
/// Layouts for all three generations, ported from `gan-web-bluetooth` by Andy
/// Fedotov (MIT):  https://github.com/afedotov/gan-web-bluetooth
///
/// Generations 3 and 4 only report moves once they have sent a position, so the
/// caller tracks whether that has happened and ignores moves until it has.
enum GANMessageDecoder {

    enum Event: Equatable, Sendable {
        case moves([GANProtocol.Turn])
        case facelets(serial: Int, state: CubeState)
        case orientation(CubeOrientation.Quaternion)
        case battery(percent: Int)
        case hardware(name: String)
        case disconnected
        case ignored
    }

    static func decode(_ bytes: [UInt8],
                       generation: GANProtocol.Generation,
                       lastSerial: Int?) -> Event? {
        switch generation {
        case .gen2: return decodeGen2(bytes, lastSerial: lastSerial)
        case .gen3: return decodeGen3(bytes)
        case .gen4: return decodeGen4(bytes)
        }
    }

    // MARK: - Generation 2

    static func decodeGen2(_ bytes: [UInt8], lastSerial: Int?) -> Event? {
        let reader = GANProtocol.BitReader(bytes: bytes)
        switch reader.word(at: 0, bits: 4) {
        case 0x01:
            return orientation(reader, at: 4)
        case 0x02:
            return decodeGen2Moves(reader, lastSerial: lastSerial)
        case 0x04:
            return facelets(serial: reader.word(at: 4, bits: 8),
                            reader: reader,
                            cornerPermutation: 12, cornerOrientation: 33,
                            edgePermutation: 47, edgeOrientation: 91)
        case 0x09:
            return .battery(percent: reader.word(at: 8, bits: 8))
        case 0x0D:
            return .disconnected
        default:
            return .ignored
        }
    }

    private static func decodeGen2Moves(_ reader: GANProtocol.BitReader,
                                        lastSerial: Int?) -> Event {
        let serial = reader.word(at: 4, bits: 8)
        // The cube keeps a rolling count and re-sends the last few turns every
        // time, so only the ones not seen yet are taken.
        let unseen = lastSerial.map { min((serial &- $0) & 0xFF, 7) } ?? 1
        guard unseen > 0 else { return .moves([]) }

        var turns: [GANProtocol.Turn] = []
        // They arrive newest first, so they are read back to front.
        for offset in stride(from: unseen - 1, through: 0, by: -1) {
            let face = reader.word(at: 12 + 5 * offset, bits: 4)
            let direction = reader.word(at: 16 + 5 * offset, bits: 1)
            guard (0..<6).contains(face) else { continue }
            turns.append(GANProtocol.Turn(label: face,
                                          clockwise: direction == 0,
                                          serial: (serial - offset) & 0xFF))
        }
        return .moves(turns)
    }

    // MARK: - Generation 3

    static func decodeGen3(_ bytes: [UInt8]) -> Event? {
        let reader = GANProtocol.BitReader(bytes: bytes)
        guard reader.word(at: 0, bits: 8) == 0x55 else { return nil }   // magic
        guard reader.word(at: 16, bits: 8) > 0 else { return .ignored } // length

        switch reader.word(at: 8, bits: 8) {
        case 0x01:
            return singleMove(reader,
                              serialAt: 56, directionAt: 72, faceAt: 74)
        case 0x02:
            return facelets(serial: reader.word(at: 24, bits: 16, littleEndian: true),
                            reader: reader,
                            cornerPermutation: 40, cornerOrientation: 61,
                            edgePermutation: 77, edgeOrientation: 121)
        case 0x10:
            return .battery(percent: reader.word(at: 24, bits: 8))
        case 0x11:
            return .disconnected
        default:
            return .ignored
        }
    }

    // MARK: - Generation 4

    static func decodeGen4(_ bytes: [UInt8]) -> Event? {
        let reader = GANProtocol.BitReader(bytes: bytes)
        switch reader.word(at: 0, bits: 8) {
        case 0x01:
            return singleMove(reader,
                              serialAt: 48, directionAt: 64, faceAt: 66)
        case 0xED:
            return facelets(serial: reader.word(at: 16, bits: 16, littleEndian: true),
                            reader: reader,
                            cornerPermutation: 32, cornerOrientation: 53,
                            edgePermutation: 69, edgeOrientation: 113)
        case 0xEF:
            return .battery(percent: reader.word(at: 24, bits: 8))
        case 0xEA:
            return .disconnected
        default:
            return .ignored
        }
    }

    // MARK: - Shared shapes

    /// Generations 3 and 4 send one move at a time, with the face as a set bit.
    private static func singleMove(_ reader: GANProtocol.BitReader,
                                   serialAt: Int, directionAt: Int, faceAt: Int) -> Event {
        let serial = reader.word(at: serialAt, bits: 16, littleEndian: true)
        let direction = reader.word(at: directionAt, bits: 2)
        guard let face = GANProtocol.faceIndex(fromBits: reader.word(at: faceAt, bits: 6)) else {
            return .ignored
        }
        return .moves([GANProtocol.Turn(label: face,
                                        clockwise: direction == 0,
                                        serial: serial & 0xFF)])
    }

    /// The cube's own sense of which way up it is, as a quaternion.
    ///
    /// Four sixteen-bit words, each sign-and-magnitude: the top bit is the
    /// sign and the rest is a fraction of 0x7FFF. The offsets come from
    /// `gan-web-bluetooth` like everything else here, and are the one part of
    /// this that has never been held against real hardware — so nothing is
    /// taken on trust. ``CubeOrientation`` is only ever believed once it has
    /// agreed with a grip worked out some other way, and a reading that is not
    /// a rotation at all is thrown out by ``CubeOrientation/Quaternion/isUsable``.
    /// If these offsets are wrong the app behaves exactly as it did before the
    /// cube had a motion sensor at all.
    private static func orientation(_ reader: GANProtocol.BitReader,
                                    at start: Int) -> Event? {
        func part(_ index: Int) -> Double {
            let raw = reader.word(at: start + 16 * index, bits: 16)
            let sign = (raw >> 15) == 1 ? -1.0 : 1.0
            return sign * Double(raw & 0x7FFF) / Double(0x7FFF)
        }
        let quaternion = CubeOrientation.Quaternion(w: part(0), x: part(1),
                                                    y: part(2), z: part(3))
        return quaternion.isUsable ? .orientation(quaternion) : .ignored
    }

    /// Every generation packs the position the same way — seven corners, eleven
    /// edges, the last of each implied — only at different offsets.
    private static func facelets(serial: Int,
                                 reader: GANProtocol.BitReader,
                                 cornerPermutation: Int, cornerOrientation: Int,
                                 edgePermutation: Int, edgeOrientation: Int) -> Event? {
        var cp: [Int] = [], co: [Int] = [], ep: [Int] = [], eo: [Int] = []
        for index in 0..<7 {
            cp.append(reader.word(at: cornerPermutation + index * 3, bits: 3))
            co.append(reader.word(at: cornerOrientation + index * 2, bits: 2))
        }
        for index in 0..<11 {
            ep.append(reader.word(at: edgePermutation + index * 4, bits: 4))
            eo.append(reader.word(at: edgeOrientation + index, bits: 1))
        }

        let whole = GANProtocol.completing(cornerPermutation: cp, cornerOrientation: co,
                                           edgePermutation: ep, edgeOrientation: eo)
        guard let state = GANProtocol.cubeState(cornerPermutation: whole.cp,
                                                cornerOrientation: whole.co,
                                                edgePermutation: whole.ep,
                                                edgeOrientation: whole.eo),
              state.isValid else {
            // A position that cannot exist means the offsets are wrong, not
            // that the cube is broken. Better to report nothing than to mislead.
            return nil
        }
        return .facelets(serial: serial, state: state)
    }
}
