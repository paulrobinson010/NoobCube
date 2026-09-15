import CommonCrypto
import Foundation

/// Reading GAN smart cube messages.
///
/// GAN do not publish their protocol; everything here comes from the public
/// reverse-engineering work behind `gan-web-bluetooth` and similar projects.
/// That means two things:
///
///   * All the magic numbers live in this one file, clearly marked, so they can
///     be corrected in one place.
///   * Nothing else in the app depends on this working. If a message cannot be
///     decoded the cube is simply ignored and the camera is used instead.
///
/// **These constants have not been checked against real hardware in this
/// build.** They need verifying with an actual cube before the smart cube
/// feature can be trusted.
enum GANProtocol {

    // MARK: - Bluetooth identifiers

    enum Generation: String, CaseIterable, Sendable {
        case gen2, gen3, gen4

        var serviceUUID: String {
            switch self {
            case .gen2: return "6E400001-B5A3-F393-E0A9-E50E24DC4179"
            case .gen3: return "8653000A-43E6-47B7-9CB0-5FC21D4AE340"
            case .gen4: return "00000010-0000-FFF7-FFF6-FFF5FFF4FFF0"
            }
        }

        /// The characteristic the cube pushes state and move events on.
        var stateCharacteristicUUID: String {
            switch self {
            case .gen2: return "28BE4CB6-CD67-11E9-A32F-2A2AE2DBCCE4"
            case .gen3: return "8653000B-43E6-47B7-9CB0-5FC21D4AE340"
            case .gen4: return "0000FFF6-0000-1000-8000-00805F9B34FB"
            }
        }

        /// The characteristic commands are written to.
        var commandCharacteristicUUID: String {
            switch self {
            case .gen2: return "28BE4A4A-CD67-11E9-A32F-2A2AE2DBCCE4"
            case .gen3: return "8653000C-43E6-47B7-9CB0-5FC21D4AE340"
            case .gen4: return "0000FFF5-0000-1000-8000-00805F9B34FB"
            }
        }
    }

    // MARK: - Encryption

    /// Base keys published by the reverse-engineering community. The real key
    /// is these with the cube's MAC address mixed into the first six bytes.
    private static let baseKeys: [(key: [UInt8], iv: [UInt8])] = [
        (key: [0x01, 0x02, 0x42, 0x28, 0x31, 0x91, 0x16, 0x07,
               0x20, 0x05, 0x18, 0x54, 0x42, 0x11, 0x12, 0x53],
         iv: [0x11, 0x03, 0x32, 0x28, 0x21, 0x01, 0x76, 0x27,
              0x20, 0x95, 0x78, 0x14, 0x32, 0x12, 0x03, 0x92]),
        (key: [0x05, 0x12, 0x02, 0x45, 0x02, 0x01, 0x29, 0x56,
               0x12, 0x78, 0x12, 0x76, 0x81, 0x01, 0x08, 0x03],
         iv: [0x01, 0x44, 0x28, 0x06, 0x86, 0x21, 0x22, 0x28,
              0x51, 0x05, 0x08, 0x31, 0x82, 0x02, 0x21, 0x06]),
    ]

    struct Cipher {
        let key: [UInt8]
        let iv: [UInt8]
    }

    /// Mix the cube's MAC address into the base key.
    ///
    /// The `% 255` is not a typo for `% 256`: it is what the cubes actually do.
    static func cipher(generation: Generation, macAddress: [UInt8]) -> Cipher? {
        guard macAddress.count == 6 else { return nil }
        let base = generation == .gen2 ? baseKeys[0] : baseKeys[1]
        var key = base.key
        var iv = base.iv
        for index in 0..<6 {
            key[index] = UInt8((Int(key[index]) + Int(macAddress[5 - index])) % 255)
            iv[index] = UInt8((Int(iv[index]) + Int(macAddress[5 - index])) % 255)
        }
        return Cipher(key: key, iv: iv)
    }

    /// Decrypt a message in place.
    ///
    /// Messages are encrypted as two overlapping 16 byte blocks: the last block
    /// first, then the first. Each block is AES-128 in CBC mode, which for a
    /// single block is an ECB decrypt followed by a XOR with the IV.
    static func decrypt(_ message: [UInt8], using cipher: Cipher) -> [UInt8]? {
        guard message.count >= 16 else { return nil }
        var buffer = message
        if buffer.count > 16 {
            guard decryptBlock(&buffer, at: buffer.count - 16, using: cipher) else { return nil }
        }
        guard decryptBlock(&buffer, at: 0, using: cipher) else { return nil }
        return buffer
    }

    private static func decryptBlock(_ buffer: inout [UInt8], at offset: Int,
                                     using cipher: Cipher) -> Bool {
        let block = Array(buffer[offset..<(offset + 16)])
        guard let plain = aesECBDecrypt(block: block, key: cipher.key) else { return false }
        for index in 0..<16 {
            buffer[offset + index] = plain[index] ^ cipher.iv[index]
        }
        return true
    }

    /// Encrypt a command for the cube: the mirror of ``decrypt(_:using:)``,
    /// so the first block goes first and the last block second.
    static func encrypt(_ message: [UInt8], using cipher: Cipher) -> [UInt8]? {
        guard message.count >= 16 else { return nil }
        var buffer = message
        guard encryptBlock(&buffer, at: 0, using: cipher) else { return nil }
        if buffer.count > 16 {
            guard encryptBlock(&buffer, at: buffer.count - 16, using: cipher) else { return nil }
        }
        return buffer
    }

    private static func encryptBlock(_ buffer: inout [UInt8], at offset: Int,
                                     using cipher: Cipher) -> Bool {
        var block = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            block[index] = buffer[offset + index] ^ cipher.iv[index]
        }
        guard let encoded = aesECBCrypt(block: block, key: cipher.key, encrypt: true) else {
            return false
        }
        for index in 0..<16 {
            buffer[offset + index] = encoded[index]
        }
        return true
    }

    private static func aesECBDecrypt(block: [UInt8], key: [UInt8]) -> [UInt8]? {
        aesECBCrypt(block: block, key: key, encrypt: false)
    }

    private static func aesECBCrypt(block: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        // Read the lengths up front: asking `output` for its count inside
        // withUnsafeMutableBytes overlaps with the exclusive access it holds.
        let keyLength = key.count
        let blockLength = block.count
        let outputLength = output.count
        let status = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, keyLength,
                            nil,
                            inputBytes.baseAddress, blockLength,
                            outputBytes.baseAddress, outputLength,
                            &moved)
                }
            }
        }
        return status == kCCSuccess ? output : nil
    }

    // MARK: - Bit reading

    /// Reads big-endian bit fields out of a message, which is how the cube
    /// packs everything.
    struct BitReader {
        let bytes: [UInt8]

        func word(at offset: Int, bits: Int) -> Int {
            var result = 0
            for index in 0..<bits {
                let bit = offset + index
                let byte = bit / 8
                guard byte < bytes.count else { return result << (bits - index) }
                let shift = 7 - (bit % 8)
                result = (result << 1) | Int((bytes[byte] >> UInt8(shift)) & 1)
            }
            return result
        }
    }

    // MARK: - Turning cube pieces into a cube state

    /// Corner slots in the order the cube reports them.
    static let cornerOrder: [Set<Face>] = [
        [.U, .R, .F], [.U, .F, .L], [.U, .L, .B], [.U, .B, .R],
        [.D, .F, .R], [.D, .L, .F], [.D, .B, .L], [.D, .R, .B],
    ]

    /// Edge slots in the order the cube reports them.
    static let edgeOrder: [Set<Face>] = [
        [.U, .R], [.U, .F], [.U, .L], [.U, .B],
        [.D, .R], [.D, .F], [.D, .L], [.D, .B],
        [.F, .R], [.F, .L], [.B, .L], [.B, .R],
    ]

    /// Build a cube state from the piece positions and twists the cube reports.
    ///
    /// The app's own slot ordering already matches the convention the cube uses
    /// — U or D sticker first, then clockwise — so pieces map across directly.
    static func cubeState(cornerPermutation: [Int], cornerOrientation: [Int],
                          edgePermutation: [Int], edgeOrientation: [Int]) -> CubeState? {
        guard cornerPermutation.count == 8, cornerOrientation.count == 8,
              edgePermutation.count == 12, edgeOrientation.count == 12 else { return nil }

        var facelets = [Face?](repeating: nil, count: 54)
        for face in Face.allCases {
            facelets[face.centreIndex] = face
        }

        for slotIndex in 0..<8 {
            let pieceIndex = cornerPermutation[slotIndex]
            guard cornerOrder.indices.contains(pieceIndex),
                  let slot = CubeSlots.slot(with: cornerOrder[slotIndex]),
                  let piece = CubeSlots.slot(with: cornerOrder[pieceIndex]) else { return nil }
            let twist = ((cornerOrientation[slotIndex] % 3) + 3) % 3
            for position in 0..<3 {
                facelets[slot.indices[(position + twist) % 3]] = piece.faces[position]
            }
        }

        for slotIndex in 0..<12 {
            let pieceIndex = edgePermutation[slotIndex]
            guard edgeOrder.indices.contains(pieceIndex),
                  let slot = CubeSlots.slot(with: edgeOrder[slotIndex]),
                  let piece = CubeSlots.slot(with: edgeOrder[pieceIndex]) else { return nil }
            let flip = ((edgeOrientation[slotIndex] % 2) + 2) % 2
            for position in 0..<2 {
                facelets[slot.indices[(position + flip) % 2]] = piece.faces[position]
            }
        }

        let resolved = facelets.compactMap { $0 }
        guard resolved.count == 54 else { return nil }
        return CubeState(facelets: resolved)
    }

    /// The last corner and edge are not sent: they are whatever makes the
    /// permutation and the twists add up.
    static func completing(cornerPermutation: [Int], cornerOrientation: [Int],
                           edgePermutation: [Int], edgeOrientation: [Int])
        -> (cp: [Int], co: [Int], ep: [Int], eo: [Int]) {
        var cp = cornerPermutation
        var co = cornerOrientation
        var ep = edgePermutation
        var eo = edgeOrientation

        let missingCorner = (0..<8).first { !cp.contains($0) } ?? 7
        cp.append(missingCorner)
        co.append((3 - (co.reduce(0, +) % 3)) % 3)

        let missingEdge = (0..<12).first { !ep.contains($0) } ?? 11
        ep.append(missingEdge)
        eo.append(eo.reduce(0, +) % 2)

        return (cp, co, ep, eo)
    }

    /// A move the cube says was made.
    struct Turn: Equatable, Sendable {
        let move: Move
        let serial: Int
    }

    /// The cube reports faces in the order U R F D L B.
    static func move(faceIndex: Int, clockwise: Bool) -> Move? {
        let bases: [MoveBase] = [.U, .R, .F, .D, .L, .B]
        guard bases.indices.contains(faceIndex) else { return nil }
        return Move(bases[faceIndex], clockwise ? .clockwise : .counterClockwise)
    }
}
