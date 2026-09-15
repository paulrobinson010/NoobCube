import Foundation

/// Turns a decrypted GAN message into something the app understands.
///
/// Only the second generation protocol is decoded here. The layouts for the
/// third and fourth generation cubes are not reliably known to this build, so
/// rather than guess at bit offsets and feed the solver nonsense, those cubes
/// report themselves as unsupported and the app falls back to the camera.
enum GANMessageDecoder {

    enum Event: Equatable, Sendable {
        case moves([GANProtocol.Turn])
        case facelets(serial: Int, state: CubeState)
        case battery(percent: Int)
        case hardware(name: String)
        case unsupported
    }

    /// Decode a message from a generation 2 cube.
    ///
    /// Field positions come from public reverse-engineering and are the part of
    /// this file most likely to need correcting against real hardware.
    static func decodeGen2(_ bytes: [UInt8], lastSerial: Int?) -> Event? {
        let reader = GANProtocol.BitReader(bytes: bytes)
        let eventType = reader.word(at: 0, bits: 4)

        switch eventType {
        case 0x02:
            return decodeGen2Moves(reader, lastSerial: lastSerial)
        case 0x04:
            return decodeGen2Facelets(reader)
        case 0x09:
            return .battery(percent: reader.word(at: 8, bits: 8))
        case 0x05:
            return .hardware(name: "GAN")
        default:
            return nil
        }
    }

    private static func decodeGen2Moves(_ reader: GANProtocol.BitReader,
                                        lastSerial: Int?) -> Event {
        let serial = reader.word(at: 4, bits: 8)
        // The cube keeps a rolling count and sends the last few turns every
        // time, so only the ones not seen yet are taken.
        let unseen: Int
        if let lastSerial {
            unseen = min((serial &- lastSerial) & 0xFF, 7)
        } else {
            unseen = 1
        }
        guard unseen > 0 else { return .moves([]) }

        var turns: [GANProtocol.Turn] = []
        // They arrive newest first, so they are read back to front.
        for offset in stride(from: unseen - 1, through: 0, by: -1) {
            let faceIndex = reader.word(at: 12 + 5 * offset, bits: 4)
            let direction = reader.word(at: 16 + 5 * offset, bits: 1)
            guard let move = GANProtocol.move(faceIndex: faceIndex, clockwise: direction == 0) else {
                continue
            }
            turns.append(GANProtocol.Turn(move: move, serial: (serial - offset) & 0xFF))
        }
        return .moves(turns)
    }

    private static func decodeGen2Facelets(_ reader: GANProtocol.BitReader) -> Event? {
        let serial = reader.word(at: 4, bits: 8)

        var cornerPermutation: [Int] = []
        var cornerOrientation: [Int] = []
        for index in 0..<7 {
            cornerPermutation.append(reader.word(at: 12 + index * 3, bits: 3))
            cornerOrientation.append(reader.word(at: 33 + index * 2, bits: 2))
        }

        var edgePermutation: [Int] = []
        var edgeOrientation: [Int] = []
        for index in 0..<11 {
            edgePermutation.append(reader.word(at: 47 + index * 4, bits: 4))
            edgeOrientation.append(reader.word(at: 91 + index, bits: 1))
        }

        let completed = GANProtocol.completing(cornerPermutation: cornerPermutation,
                                               cornerOrientation: cornerOrientation,
                                               edgePermutation: edgePermutation,
                                               edgeOrientation: edgeOrientation)
        guard let state = GANProtocol.cubeState(cornerPermutation: completed.cp,
                                                cornerOrientation: completed.co,
                                                edgePermutation: completed.ep,
                                                edgeOrientation: completed.eo),
              state.isValid else {
            // A state that cannot exist means the layout is wrong, not that the
            // cube is broken. Better to report nothing than to mislead.
            return nil
        }
        return .facelets(serial: serial, state: state)
    }
}
