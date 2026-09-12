import Foundation
import CryptoKit

// MARK: - xxHash64

/// 流式 xxHash64 实现。
///
/// 按 xxHash 官方规范实现，`update` 可被多次调用，输出与参考实现 `xxhsum -H64` 一致。
/// 选择自实现而非引入第三方依赖，是为了保持工程零外部依赖、便于随 App 一起签名分发。
struct XXHash64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var totalLength: UInt64 = 0
    private var buffer: [UInt8] = []
    private var finished = false

    init(seed: UInt64 = 0) {
        self.seed = seed
        self.v1 = seed &+ Self.p1 &+ Self.p2
        self.v2 = seed &+ Self.p2
        self.v3 = seed
        self.v4 = seed &- Self.p1
        buffer.reserveCapacity(64)
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* p2)
        a = rotl(a, 31)
        a &*= p1
        return a
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let a = acc ^ round(0, val)
        return a &* p1 &+ p4
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 {
            value |= UInt64(bytes[offset + k]) << (8 * UInt64(k))
        }
        return value
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for k in 0..<4 {
            value |= UInt32(bytes[offset + k]) << (8 * UInt32(k))
        }
        return value
    }

    private mutating func consume(block: ArraySlice<UInt8>) {
        let b = Array(block)
        v1 = Self.round(v1, Self.readUInt64(b, 0))
        v2 = Self.round(v2, Self.readUInt64(b, 8))
        v3 = Self.round(v3, Self.readUInt64(b, 16))
        v4 = Self.round(v4, Self.readUInt64(b, 24))
    }

    mutating func update(_ data: [UInt8]) {
        guard !finished, !data.isEmpty else { return }
        totalLength &+= UInt64(data.count)

        var offset = 0

        if buffer.count + data.count < 32 {
            buffer.append(contentsOf: data)
            return
        }

        if !buffer.isEmpty {
            let need = 32 - buffer.count
            buffer.append(contentsOf: data[0..<need])
            consume(block: buffer[0..<32])
            buffer.removeAll(keepingCapacity: true)
            offset = need
        }

        while data.count - offset >= 32 {
            consume(block: data[offset..<(offset + 32)])
            offset += 32
        }

        if offset < data.count {
            buffer.append(contentsOf: data[offset..<data.count])
        }
    }

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        update([UInt8](data))
    }

    mutating func finalize() -> UInt64 {
        finished = true

        var h: UInt64
        if totalLength >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.mergeRound(h, v1)
            h = Self.mergeRound(h, v2)
            h = Self.mergeRound(h, v3)
            h = Self.mergeRound(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= totalLength

        var offset = 0
        while buffer.count - offset >= 8 {
            h ^= Self.round(0, Self.readUInt64(buffer, offset))
            h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
            offset += 8
        }
        if buffer.count - offset >= 4 {
            h ^= UInt64(Self.readUInt32(buffer, offset)) &* Self.p1
            h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
            offset += 4
        }
        while offset < buffer.count {
            h ^= UInt64(buffer[offset]) &* Self.p5
            h = Self.rotl(h, 11) &* Self.p1
            offset += 1
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// 一次性计算，便于测试与小型数据。
    static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        var hasher = XXHash64(seed: seed)
        hasher.update(bytes)
        return hasher.finalize()
    }
}

// MARK: - 统一流式哈希器

/// 屏蔽具体算法差异的流式哈希入口。
struct StreamingHasher {
    private enum Backing {
        case none
        case xxhash64(XXHash64)
        case sha256(SHA256)
        case md5(Insecure.MD5)
    }

    private var backing: Backing
    let algorithm: CheckAlgorithm

    init(algorithm: CheckAlgorithm) {
        self.algorithm = algorithm
        switch algorithm {
        case .none: backing = .none
        case .xxhash64: backing = .xxhash64(XXHash64())
        case .sha256: backing = .sha256(SHA256())
        case .md5: backing = .md5(Insecure.MD5())
        }
    }

    mutating func update(_ data: Data) {
        switch backing {
        case .none:
            break
        case .xxhash64(var h):
            h.update(data)
            backing = .xxhash64(h)
        case .sha256(var h):
            h.update(data: data)
            backing = .sha256(h)
        case .md5(var h):
            h.update(data: data)
            backing = .md5(h)
        }
    }

    /// 返回十六进制摘要；`none` 算法返回 nil。
    mutating func digestHex() -> String? {
        switch backing {
        case .none:
            return nil
        case .xxhash64(var h):
            let value = h.finalize()
            backing = .xxhash64(h)
            return String(format: "%016llx", value)
        case .sha256(let h):
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        case .md5(let h):
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

extension String {
    /// 长度自校验：用于拦截截断或格式错误的摘要。
    func isValidDigest(for algorithm: CheckAlgorithm) -> Bool {
        guard algorithm != .none else { return true }
        guard count == algorithm.digestHexLength else { return false }
        return allSatisfy { $0.isHexDigit }
    }
}
