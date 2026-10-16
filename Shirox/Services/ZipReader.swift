import Compression
import Foundation

/// Reads one file out of a zip — enough for a SkyStream `.sky` (stored or deflated entries).
enum ZipReader {
    /// `maxSize` bounds what's unpacked: a file claiming more is refused rather than allocated.
    static func file(named name: String, in zip: Data, maxSize: Int = 32 << 20) -> Data? {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // The end of the central directory: the last "PK\u{5}\u{6}".
        guard bytes.count >= 22 else { return nil }
        var eocd = -1
        for o in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
        where bytes[o] == 0x50 && bytes[o + 1] == 0x4b && bytes[o + 2] == 5 && bytes[o + 3] == 6 {
            eocd = o
            break
        }
        guard eocd >= 0 else { return nil }
        var o = u32(eocd + 16)
        for _ in 0..<u16(eocd + 10) {
            guard u32(o) == 0x0201_4b50 else { return nil }
            let method = u16(o + 10), compressed = u32(o + 20), size = u32(o + 24)
            let nameLength = u16(o + 28), extraLength = u16(o + 30), commentLength = u16(o + 32)
            let local = u32(o + 42)
            guard o + 46 + nameLength <= bytes.count else { return nil }
            let entryName = String(decoding: bytes[(o + 46)..<(o + 46 + nameLength)], as: UTF8.self)
            if entryName == name {
                guard u32(local) == 0x0403_4b50, size <= maxSize, compressed <= maxSize else { return nil }
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                guard start + compressed <= bytes.count else { return nil }
                let payload = Array(bytes[start..<(start + compressed)])
                switch method {
                case 0: return Data(payload)
                case 8: return inflate(payload, size: size)
                default: return nil
                }
            }
            o += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    /// Raw DEFLATE, which is what Apple's `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ input: [UInt8], size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = compression_decode_buffer(&output, size, input, input.count, nil, COMPRESSION_ZLIB)
        return written == size ? Data(output) : nil
    }
}
