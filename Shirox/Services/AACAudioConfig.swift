import Foundation

/// An AAC track's AudioSpecificConfig: the few bytes an MP4 keeps to tell the decoder what the
/// audio is.
///
/// A transport stream has none. Each frame carries an ADTS header instead, and ADTS can't say
/// "HE-AAC" (SBR) or "HE-AAC v2" (Parametric Stereo): those are left for the decoder to find in
/// the audio itself. Copied into an MP4 as it is, the config says what the header said, which on
/// AnimePahe's streams is even "AAC Main", a profile Apple's decoder doesn't play at all, so
/// AVPlayer stayed silent where mpv, which looks at the audio, played it. `explicit` writes what
/// the audio really is.
struct AACAudioConfig: Equatable {
    /// 1 Main, 2 LC, 5 SBR (HE-AAC), 29 PS (HE-AAC v2).
    var objectType: Int
    /// The core's sample rate: half the output's with SBR.
    var sampleRate: Int
    var channelConfiguration: Int
    /// The output's rate, set when SBR doubles it.
    var extensionSampleRate: Int?

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    // MARK: Reading

    /// The config at the start of an MP4's `esds` (FFmpeg's extradata).
    init?(audioSpecificConfig bytes: [UInt8]) {
        var bits = BitReader(bytes)
        guard let type = bits.objectType(), let rate = bits.sampleRate(),
              let channels = bits.read(4) else { return nil }
        var extensionRate: Int?
        if type == 5 || type == 29 {
            guard let ext = bits.sampleRate(), let core = bits.objectType() else { return nil }
            extensionRate = ext
            // The hierarchical form names the extension first and the core after; this keeps
            // the extension, as `explicit` writes it back.
            _ = core
        }
        if type == 0 { return nil }
        self.init(objectType: type, sampleRate: rate, channelConfiguration: channels,
                  extensionSampleRate: extensionRate)
    }

    /// The config an ADTS header describes. Nil when the bytes aren't one.
    init?(adtsHeader bytes: [UInt8]) {
        guard let header = ADTSHeader(bytes) else { return nil }
        guard header.sampleRateIndex < Self.sampleRates.count else { return nil }
        self.init(objectType: header.profile + 1, sampleRate: Self.sampleRates[header.sampleRateIndex],
                  channelConfiguration: header.channelConfiguration, extensionSampleRate: nil)
    }

    init(objectType: Int, sampleRate: Int, channelConfiguration: Int, extensionSampleRate: Int?) {
        self.objectType = objectType
        self.sampleRate = sampleRate
        self.channelConfiguration = channelConfiguration
        self.extensionSampleRate = extensionSampleRate
    }

    var signalsSBR: Bool { objectType == 5 || objectType == 29 }

    // MARK: Fixing

    /// The config for what a decoder found the audio to be: SBR when it put out twice the core's
    /// rate. A mono core with SBR is signalled as HE-AAC v2, Parametric Stereo: FFmpeg ignores PS
    /// it wasn't told about, so it can't say whether there is any, and announced but absent it
    /// costs nothing (the decoder plays the mono on both sides). Main becomes LC: real Main audio
    /// is all but extinct, the label on these streams is wrong, and Apple can't decode Main.
    func explicit(decodedRate: Int) -> AACAudioConfig {
        let sbr = decodedRate == sampleRate * 2 || (signalsSBR && extensionSampleRate != nil)
        let ps = sbr && (objectType == 29 || channelConfiguration == 1)
        if sbr {
            return AACAudioConfig(objectType: ps ? 29 : 5, sampleRate: sampleRate,
                                  channelConfiguration: channelConfiguration,
                                  extensionSampleRate: extensionSampleRate ?? sampleRate * 2)
        }
        return AACAudioConfig(objectType: objectType == 1 ? 2 : objectType, sampleRate: sampleRate,
                              channelConfiguration: channelConfiguration, extensionSampleRate: nil)
    }

    /// Whether an MP4 holding `self` needs `fixed` instead: Apple's decoder can't play it as it
    /// is, or would miss the SBR/PS half of it.
    func needsReplacing(by fixed: AACAudioConfig) -> Bool {
        objectType == 1 || (fixed.signalsSBR && !signalsSBR)
    }

    // MARK: Writing

    /// The AudioSpecificConfig bytes, explicit hierarchical signaling for SBR and PS.
    var bytes: [UInt8] {
        var bits = BitWriter()
        bits.objectType(objectType)
        bits.sampleRate(sampleRate)
        bits.write(channelConfiguration, 4)
        if signalsSBR {
            bits.sampleRate(extensionSampleRate ?? sampleRate * 2)
            bits.objectType(2)
        }
        // GASpecificConfig: 1024-sample frames, no core coder, no extension.
        bits.write(0, 3)
        return bits.bytes
    }
}

/// The fixed part of an ADTS header, and its length.
struct ADTSHeader: Equatable {
    var profile: Int
    var sampleRateIndex: Int
    var channelConfiguration: Int
    var frameLength: Int
    /// Frames after the first in this one; 0 almost always.
    var extraRawBlocks: Int
    /// 7 bytes, or 9 with a CRC.
    var length: Int

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 7, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 else { return nil }
        let crcAbsent = bytes[1] & 0x01 == 1
        profile = Int(bytes[2] >> 6)
        sampleRateIndex = Int((bytes[2] >> 2) & 0x0F)
        channelConfiguration = Int((bytes[2] & 0x01) << 2 | bytes[3] >> 6)
        frameLength = Int(bytes[3] & 0x03) << 11 | Int(bytes[4]) << 3 | Int(bytes[5] >> 5)
        extraRawBlocks = Int(bytes[6] & 0x03)
        length = crcAbsent ? 7 : 9
    }
}

private struct BitReader {
    let bytes: [UInt8]
    var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            value = value << 1 | Int(bit)
            position += 1
        }
        return value
    }

    mutating func objectType() -> Int? {
        guard let type = read(5) else { return nil }
        guard type == 31 else { return type }
        return read(6).map { 32 + $0 }
    }

    mutating func sampleRate() -> Int? {
        guard let index = read(4) else { return nil }
        if index == 15 { return read(24) }
        return index < AACAudioConfig.sampleRates.count ? AACAudioConfig.sampleRates[index] : nil
    }
}

private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 0

    mutating func write(_ value: Int, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if used % 8 == 0 { bytes.append(0) }
            if (value >> shift) & 1 == 1 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(used % 8)) }
            used += 1
        }
    }

    mutating func objectType(_ type: Int) {
        if type >= 32 { write(31, 5); write(type - 32, 6) } else { write(type, 5) }
    }

    mutating func sampleRate(_ rate: Int) {
        if let index = AACAudioConfig.sampleRates.firstIndex(of: rate) { write(index, 4) } else { write(15, 4); write(rate, 24) }
    }
}
