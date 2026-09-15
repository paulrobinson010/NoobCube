import CommonCrypto
import Foundation

/// Reading GAN smart cube messages.
///
/// GAN do not publish their protocol. The service identifiers, keys, message
/// layouts and bit offsets here are ported from `gan-web-bluetooth` by Andy
/// Fedotov (MIT licensed), which is the reference reverse-engineering of these
/// cubes:  https://github.com/afedotov/gan-web-bluetooth
///
/// The piece-to-sticker reconstruction was checked against that project's own
/// worked example, and against this app's move engine, which agree.
///
/// Still unverified against real hardware: whether the MAC address can be read
/// from the advertisement on iOS. Everything fails soft if not — the app says
/// what it saw and falls back to the camera.
enum GANProtocol {

    // MARK: - Bluetooth identifiers

    enum Generation: String, CaseIterable, Sendable {
        case gen2, gen3, gen4

        /// Which cubes speak this version, so the app can say something useful
        /// when it meets one it cannot read.
        var models: String {
            switch self {
            case .gen2:
                return "GAN Mini ui FreePlay, GAN12 ui, GAN12 ui FreePlay, "
                     + "GAN356 i Carry, GAN356 i Carry S, GAN356 i 3, Monster Go 3Ai"
            case .gen3:
                return "GAN356 i Carry 2"
            case .gen4:
                return "GAN12 ui Maglev, GAN14 ui FreePlay"
            }
        }

        /// How long a command message is for this generation.
        var commandLength: Int {
            self == .gen3 ? 16 : 20
        }

        /// The command asking the cube to report its current position.
        var requestFaceletsCommand: [UInt8] {
            var message = [UInt8](repeating: 0, count: commandLength)
            switch self {
            case .gen2:
                message[0] = 0x04
            case .gen3:
                message[0] = 0x68
                message[1] = 0x01
            case .gen4:
                for (index, byte) in [0xDD, 0x04, 0x00, 0xED, 0x00, 0x00].enumerated() {
                    message[index] = UInt8(byte)
                }
            }
            return message
        }

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

    /// The base key and IV. One pair covers GAN generations 2, 3 and 4 alike;
    /// the real key is this with the cube's MAC address mixed into the first
    /// six bytes.
    private static let baseKey: [UInt8] = [
        0x01, 0x02, 0x42, 0x28, 0x31, 0x91, 0x16, 0x07,
        0x20, 0x05, 0x18, 0x54, 0x42, 0x11, 0x12, 0x53,
    ]
    private static let baseIV: [UInt8] = [
        0x11, 0x03, 0x32, 0x28, 0x21, 0x01, 0x76, 0x27,
        0x20, 0x95, 0x78, 0x14, 0x32, 0x12, 0x02, 0x43,
    ]

    struct Cipher {
        let key: [UInt8]
        let iv: [UInt8]
    }

    /// Mix the cube's MAC address into the base key.
    ///
    /// The `% 255` is not a typo for `% 256`: it is what the cubes actually do.
    static func cipher(generation: Generation, salt: [UInt8]) -> Cipher? {
        guard salt.count == 6 else { return nil }
        var key = baseKey
        var iv = baseIV
        for index in 0..<6 {
            key[index] = UInt8((Int(key[index]) + Int(salt[index])) % 255)
            iv[index] = UInt8((Int(iv[index]) + Int(salt[index])) % 255)
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

        /// Read `bits` bits starting at `offset`, most significant first.
        ///
        /// Sixteen and thirty-two bit fields may also be little-endian, which
        /// is how the newer cubes send timestamps and move counters.
        func word(at offset: Int, bits: Int, littleEndian: Bool = false) -> Int {
            if bits <= 8 || !littleEndian {
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
            // Little-endian: the same bytes, least significant one first.
            var result = 0
            let count = bits / 8
            for index in stride(from: count - 1, through: 0, by: -1) {
                result = (result << 8) | word(at: offset + index * 8, bits: 8)
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

        // The eighth corner and twelfth edge are whatever make the sums work:
        // 0+...+7 is 28, 0+...+11 is 66, twists cancel mod 3 and flips mod 2.
        cp.append(28 - cp.reduce(0, +))
        co.append((3 - (co.reduce(0, +) % 3)) % 3)
        ep.append(66 - ep.reduce(0, +))
        eo.append((2 - (eo.reduce(0, +) % 2)) % 2)

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

    /// Generations 3 and 4 send the face as a single set bit rather than an
    /// index, in this order.
    static let faceBitOrder = [2, 32, 8, 1, 16, 4]

    static func faceIndex(fromBits bits: Int) -> Int? {
        faceBitOrder.firstIndex(of: bits)
    }
}
