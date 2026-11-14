import CryptoKit

/// Ed25519 signing as used by MariaDB's `client_ed25519` plugin: the expanded secret key is
/// SHA-512 of the whole password (standard Ed25519 hashes a 32-byte seed instead, so CryptoKit cannot
/// be used directly). Port of the public-domain TweetNaCl reference (radix-2^16 field elements); not
/// constant-time critical here because the password never leaves the client and one signature is made
/// per login.
public enum Ed25519 {
    /// 64-byte signature `R || S` of `message`.
    public static func sign(message: [UInt8], password: [UInt8]) -> [UInt8] {
        var expanded = Array(SHA512.hash(data: password))
        expanded[0] &= 248
        expanded[31] &= 127
        expanded[31] |= 64
        let secretScalar = Array(expanded[0..<32])
        let publicKey = Self.encode(Self.scalarMultiplyBase(secretScalar))

        var nonceInput = Array(expanded[32..<64])
        nonceInput += message
        var nonce = Array(SHA512.hash(data: nonceInput))
        nonce = reduce(nonce)
        let commitment = encode(scalarMultiplyBase(nonce))

        var hashInput = commitment
        hashInput += publicKey
        hashInput += message
        let challenge = reduce(Array(SHA512.hash(data: hashInput)))

        var wide = [Int64](repeating: 0, count: 64)
        for index in 0..<32 { wide[index] = Int64(nonce[index]) }
        for i in 0..<32 {
            for j in 0..<32 { wide[i + j] += Int64(challenge[i]) * Int64(secretScalar[j]) }
        }
        return commitment + modL(&wide)
    }

    /// The public key matching `password` (32 bytes).
    public static func publicKey(password: [UInt8]) -> [UInt8] {
        var expanded = Array(SHA512.hash(data: password))
        expanded[0] &= 248
        expanded[31] &= 127
        expanded[31] |= 64
        return encode(scalarMultiplyBase(Array(expanded[0..<32])))
    }

    // MARK: Field arithmetic modulo 2^255 - 19

    typealias Field = [Int64] // 16 limbs of 16 bits

    static let zero: Field = Array(repeating: 0, count: 16)
    static let one: Field = [1] + Array(repeating: 0, count: 15)
    static let d2: Field = [0xF159, 0x26B2, 0x9B94, 0xEBD6, 0xB156, 0x8283, 0x149A, 0x00E0,
                            0xD130, 0xEEF3, 0x80F2, 0x198E, 0xFCE7, 0x56DF, 0xD9DC, 0x2406]
    static let baseX: Field = [0xD51A, 0x8F25, 0x2D60, 0xC956, 0xA7B2, 0x9525, 0xC760, 0x692C,
                               0xDC5C, 0xFDD6, 0xE231, 0xC0A4, 0x53FE, 0xCD6E, 0x36D3, 0x2169]
    static let baseY: Field = Array(repeating: 0x6666, count: 15).reduce(into: [0x6658]) { $0.append($1) }

    static func carry(_ o: inout Field) {
        for i in 0..<16 {
            o[i] += 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] += c - 1
            } else {
                o[0] += 38 * (c - 1)
            }
            o[i] -= c * 65_536
        }
    }

    static func select(_ p: inout Field, _ q: inout Field, _ bit: Int64) {
        let mask = ~(bit - 1)
        for i in 0..<16 {
            let t = mask & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    static func pack(_ n: Field) -> [UInt8] {
        var t = n
        carry(&t)
        carry(&t)
        carry(&t)
        var m = zero
        for _ in 0..<2 {
            m[0] = t[0] - 0xFFED
            for i in 1..<15 {
                m[i] = t[i] - 0xFFFF - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xFFFF
            }
            m[15] = t[15] - 0x7FFF - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xFFFF
            select(&t, &m, 1 - b)
        }
        var output = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            output[2 * i] = UInt8(truncatingIfNeeded: t[i] & 0xFF)
            output[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return output
    }

    static func parity(_ a: Field) -> UInt8 { pack(a)[0] & 1 }

    static func add(_ a: Field, _ b: Field) -> Field { (0..<16).map { a[$0] + b[$0] } }
    static func subtract(_ a: Field, _ b: Field) -> Field { (0..<16).map { a[$0] - b[$0] } }

    static func multiply(_ a: Field, _ b: Field) -> Field {
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            for j in 0..<16 { t[i + j] += a[i] * b[j] }
        }
        for i in 0..<15 { t[i] += 38 * t[i + 16] }
        var o = Array(t[0..<16])
        carry(&o)
        carry(&o)
        return o
    }

    static func invert(_ input: Field) -> Field {
        var c = input
        for a in stride(from: 253, through: 0, by: -1) {
            c = multiply(c, c)
            if a != 2, a != 4 { c = multiply(c, input) }
        }
        return c
    }

    // MARK: Group operations (extended coordinates)

    typealias Point = [Field] // X, Y, Z, T

    static func pointAdd(_ p: inout Point, _ q: Point) {
        let a = multiply(subtract(p[1], p[0]), subtract(q[1], q[0]))
        let b = multiply(add(p[0], p[1]), add(q[0], q[1]))
        let c = multiply(multiply(p[3], q[3]), d2)
        var d = multiply(p[2], q[2])
        d = add(d, d)
        let e = subtract(b, a)
        let f = subtract(d, c)
        let g = add(d, c)
        let h = add(b, a)
        p[0] = multiply(e, f)
        p[1] = multiply(h, g)
        p[2] = multiply(g, f)
        p[3] = multiply(e, h)
    }

    static func conditionalSwap(_ p: inout Point, _ q: inout Point, _ bit: Int64) {
        for i in 0..<4 { select(&p[i], &q[i], bit) }
    }

    static func encode(_ p: Point) -> [UInt8] {
        let zInverse = invert(p[2])
        let x = multiply(p[0], zInverse)
        let y = multiply(p[1], zInverse)
        var output = pack(y)
        output[31] ^= parity(x) << 7
        return output
    }

    static func scalarMultiplyBase(_ scalar: [UInt8]) -> Point {
        var p: Point = [zero, one, one, zero]
        var q: Point = [baseX, baseY, one, multiply(baseX, baseY)]
        for i in stride(from: 255, through: 0, by: -1) {
            let bit = Int64((scalar[i / 8] >> UInt8(i & 7)) & 1)
            conditionalSwap(&p, &q, bit)
            pointAdd(&q, p)
            let copy = p
            pointAdd(&p, copy)
            conditionalSwap(&p, &q, bit)
        }
        return p
    }

    // MARK: Scalars modulo L

    static let orderL: [Int64] = [0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

    static func modL(_ x: inout [Int64]) -> [UInt8] {
        for i in stride(from: 63, through: 32, by: -1) {
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                x[j] += carry - 16 * x[i] * orderL[j - (i - 32)]
                carry = (x[j] + 128) >> 8
                x[j] -= carry * 256
                j += 1
            }
            x[j] += carry
            x[i] = 0
        }
        var carry: Int64 = 0
        for j in 0..<32 {
            x[j] += carry - (x[31] >> 4) * orderL[j]
            carry = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] -= carry * orderL[j] }
        var output = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            x[i + 1] += x[i] >> 8
            output[i] = UInt8(truncatingIfNeeded: x[i] & 255)
        }
        return output
    }

    static func reduce(_ bytes: [UInt8]) -> [UInt8] {
        var x = [Int64](repeating: 0, count: 64)
        for (index, byte) in bytes.prefix(64).enumerated() { x[index] = Int64(byte) }
        return modL(&x)
    }
}
