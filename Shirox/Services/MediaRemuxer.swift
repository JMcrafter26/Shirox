#if !os(tvOS)
import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Turns a finished HLS download — a folder of playlists and hundreds of segments — into one
/// ordinary video file, copying the streams as they are (no re-encoding, so it takes seconds).
///
/// Every video and audio stream is kept, so a download with several audio languages stays
/// switchable. MP4 is tried first, which AVPlayer, Picture in Picture and the Files app all
/// open; a codec MP4 can't carry falls back to Matroska, which plays in MPV.
enum MediaRemuxer {
    enum RemuxError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): return String(localized: "shared.couldnt_build_the_video_file \(message)") }
        }
    }

    /// Remuxes `input` into `<stem>.mp4`, or `<stem>.mkv` when MP4 won't take the streams, and
    /// returns the file written. Nothing is left at either path when it throws.
    static func remux(input: URL, toStem stem: URL) throws -> URL {
        let mp4 = stem.appendingPathExtension("mp4")
        do {
            try remux(input: input, output: mp4, format: "mp4")
            return mp4
        } catch {
            try? FileManager.default.removeItem(at: mp4)
            Logger.shared.log("[Remux] MP4 failed (\(error.localizedDescription)), trying MKV", type: "Download")
        }
        let mkv = stem.appendingPathExtension("mkv")
        do {
            try remux(input: input, output: mkv, format: "matroska")
            return mkv
        } catch {
            try? FileManager.default.removeItem(at: mkv)
            throw error
        }
    }

    /// Rewrites a downloaded MP4 whose AAC config Apple's decoder can't play (see
    /// `AACAudioConfig`), in place. False when it was fine as it was.
    static func repairAudioConfig(_ file: URL) throws -> Bool {
        let plans = try aacConfigs(for: file)
        guard plans.values.contains(where: \.needsReplacing) else { return false }
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).repair.\(file.pathExtension)")
        do {
            try remux(input: file, output: temp, format: "mp4")
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return true
    }

    /// How many audio tracks a file has; nil when it can't be read.
    static func audioTrackCount(_ file: URL) -> Int? {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, file.path, nil, nil) >= 0, let opened = ctx else { return nil }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(opened, nil) >= 0 else { return nil }
        return (0..<Int(opened.pointee.nb_streams)).filter {
            opened.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        }.count
    }

    /// One audio track to add to a file: a local HLS playlist and how to label it.
    struct AudioSource {
        var playlist: URL
        var name: String
        var language: String?
        var isDefault: Bool
    }

    /// Adds audio to a downloaded file that has none, in place: its video as it is, and each
    /// source's audio, moved onto the file's clock. The file's video was moved to start at zero
    /// when it was made, from where the stream's clock had it; `videoReference` (the stream's
    /// first video segment) says where that was, so the audio moves by the same amount.
    static func addAudio(to file: URL, from sources: [AudioSource], videoReference: URL) throws {
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).audio.\(file.pathExtension)")
        do {
            try mergeAudio(video: file, sources: sources, videoReference: videoReference, output: temp,
                           format: file.pathExtension.lowercased() == "mkv" ? "matroska" : "mp4")
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func mergeAudio(video: URL, sources: [AudioSource], videoReference: URL,
                                   output: URL, format: String) throws {
        // Where the stream's clock started the video.
        var refCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&refCtx, videoReference.path, nil, nil), "open video reference")
        defer { avformat_close_input(&refCtx) }
        guard let refCtx else { throw RemuxError.failed("no reference") }
        try check(avformat_find_stream_info(refCtx, nil), "read reference")
        let videoStart = refCtx.pointee.start_time == noPTS ? 0 : refCtx.pointee.start_time

        struct Input {
            var ctx: UnsafeMutablePointer<AVFormatContext>?
            var mapping: [Int32]
            /// Subtracted from every timestamp, in AV_TIME_BASE units.
            var shift: Int64
            var aac: [Int: AACPlan]
            var done = false
        }
        var inputs: [Input] = []
        defer { for i in inputs.indices { avformat_close_input(&inputs[i].ctx) } }

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outCtx, nil, format, output.path), "create \(format)")
        guard let outCtx else { throw RemuxError.failed("no output") }
        defer {
            if outCtx.pointee.pb != nil { avio_closep(&outCtx.pointee.pb) }
            avformat_free_context(outCtx)
        }

        func open(_ url: URL) throws -> UnsafeMutablePointer<AVFormatContext> {
            var ctx: UnsafeMutablePointer<AVFormatContext>?
            try check(avformat_open_input(&ctx, url.path, nil, nil), "open \(url.lastPathComponent)")
            guard let ctx else { throw RemuxError.failed("no input") }
            inputs.append(Input(ctx: ctx, mapping: [], shift: 0, aac: [:]))
            try check(avformat_find_stream_info(ctx, nil), "read \(url.lastPathComponent)")
            return ctx
        }

        // The file's video, as it is.
        let videoCtx = try open(video)
        var videoMapping = [Int32](repeating: -1, count: Int(videoCtx.pointee.nb_streams))
        for index in 0..<Int(videoCtx.pointee.nb_streams) {
            guard let source = videoCtx.pointee.streams[index],
                  source.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  source.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0,
                  let target = avformat_new_stream(outCtx, nil) else { continue }
            try check(avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar), "copy video")
            target.pointee.codecpar.pointee.codec_tag = 0
            target.pointee.time_base = source.pointee.time_base
            target.pointee.disposition = AV_DISPOSITION_DEFAULT
            videoMapping[index] = target.pointee.index
        }
        inputs[0].mapping = videoMapping
        guard videoMapping.contains(where: { $0 >= 0 }) else { throw RemuxError.failed("no video") }

        // Each language's audio.
        let hasDefault = sources.contains(where: \.isDefault)
        for (number, source) in sources.enumerated() {
            let ctx = try open(source.playlist)
            let plans = format == "mp4" ? try aacConfigs(for: source.playlist) : [:]
            var mapping = [Int32](repeating: -1, count: Int(ctx.pointee.nb_streams))
            for index in 0..<Int(ctx.pointee.nb_streams) {
                guard let stream = ctx.pointee.streams[index],
                      stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                      let target = avformat_new_stream(outCtx, nil) else { continue }
                try check(avcodec_parameters_copy(target.pointee.codecpar, stream.pointee.codecpar), "copy audio")
                target.pointee.codecpar.pointee.codec_tag = 0
                target.pointee.time_base = stream.pointee.time_base
                if let plan = plans[index] { setExtradata(plan.fixed.bytes, on: target.pointee.codecpar) }
                if let language = source.language {
                    av_dict_set(&target.pointee.metadata, "language", isoLanguage(language), 0)
                }
                av_dict_set(&target.pointee.metadata, "title", source.name, 0)
                av_dict_set(&target.pointee.metadata, "handler_name", source.name, 0)
                target.pointee.disposition = (hasDefault ? source.isDefault : number == 0) ? AV_DISPOSITION_DEFAULT : 0
                mapping[index] = target.pointee.index
                break // one track per rendition
            }
            let last = inputs.count - 1
            inputs[last].mapping = mapping
            inputs[last].shift = videoStart
            inputs[last].aac = plans
        }

        if outCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&outCtx.pointee.pb, output.path, AVIO_FLAG_WRITE), "create file")
        }
        var options: OpaquePointer?
        if format == "mp4" { av_dict_set(&options, "movflags", "+faststart", 0) }
        defer { av_dict_free(&options) }
        try check(avformat_write_header(outCtx, &options), "write header")

        // One packet waiting per input; the earliest goes next, so the file comes out
        // interleaved without holding whole tracks in memory.
        var pending: [UnsafeMutablePointer<AVPacket>?] = inputs.map { _ in av_packet_alloc() }
        defer { for i in pending.indices { av_packet_free(&pending[i]) } }
        var ready = [Bool](repeating: false, count: inputs.count)
        let outputCount = Int(outCtx.pointee.nb_streams)
        var lastDTS = [Int64](repeating: noPTS, count: outputCount)
        var offset = [Int64](repeating: 0, count: outputCount)
        let microseconds = AVRational(num: 1, den: 1_000_000)

        func fill(_ i: Int) throws {
            guard !inputs[i].done, !ready[i], let packet = pending[i] else { return }
            while true {
                let read = av_read_frame(inputs[i].ctx, packet)
                if read == averrorEOF { inputs[i].done = true; return }
                try check(read, "read")
                let index = Int(packet.pointee.stream_index)
                if index < inputs[i].mapping.count, inputs[i].mapping[index] >= 0 {
                    if inputs[i].aac[index] != nil { try stripADTSHeader(packet) }
                    ready[i] = true
                    return
                }
                av_packet_unref(packet)
            }
        }

        func seconds(_ i: Int) -> Double {
            guard let packet = pending[i], let stream = inputs[i].ctx?.pointee.streams[Int(packet.pointee.stream_index)] else { return .infinity }
            let ts = packet.pointee.dts != noPTS ? packet.pointee.dts : packet.pointee.pts
            guard ts != noPTS else { return -.infinity }
            return Double(ts) * av_q2d(stream.pointee.time_base) - Double(inputs[i].shift) / 1_000_000
        }

        while true {
            for i in inputs.indices { try fill(i) }
            guard let next = inputs.indices.filter({ ready[$0] }).min(by: { seconds($0) < seconds($1) }),
                  let packet = pending[next], let ctx = inputs[next].ctx else { break }
            let sourceIndex = Int(packet.pointee.stream_index)
            let source = ctx.pointee.streams[sourceIndex]!
            let targetIndex = Int(inputs[next].mapping[sourceIndex])
            let target = outCtx.pointee.streams[targetIndex]!
            packet.pointee.stream_index = Int32(targetIndex)
            av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
            packet.pointee.pos = -1
            let shift = av_rescale_q(inputs[next].shift, microseconds, target.pointee.time_base)
            if packet.pointee.dts != noPTS {
                var dts = packet.pointee.dts - shift + offset[targetIndex]
                if lastDTS[targetIndex] != noPTS, dts <= lastDTS[targetIndex] {
                    let bump = lastDTS[targetIndex] + max(packet.pointee.duration, 1) - dts
                    offset[targetIndex] += bump
                    dts += bump
                }
                packet.pointee.dts = dts
                if packet.pointee.pts != noPTS { packet.pointee.pts += offset[targetIndex] - shift }
                lastDTS[targetIndex] = dts
            } else if packet.pointee.pts != noPTS {
                packet.pointee.pts += offset[targetIndex] - shift
            }
            // Audio from before the video's first frame has nowhere to go.
            if packet.pointee.pts != noPTS, packet.pointee.pts < 0, target.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                av_packet_unref(packet)
                ready[next] = false
                continue
            }
            try check(av_interleaved_write_frame(outCtx, packet), "write")
            ready[next] = false
        }
        try check(av_write_trailer(outCtx), "finish")
    }

    // MARK: - libavformat

    private static let averrorEOF: Int32 = -0x2046_4F45 // FFERRTAG('E','O','F',' ')
    private static let noPTS = Int64.min                 // AV_NOPTS_VALUE

    private static func remux(input: URL, output: URL, format: String) throws {
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&inCtx, input.path, nil, nil), "open \(input.lastPathComponent)")
        defer { avformat_close_input(&inCtx) }
        guard let inCtx else { throw RemuxError.failed("no input") }
        try check(avformat_find_stream_info(inCtx, nil), "read stream info")

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outCtx, nil, format, output.path), "create \(format)")
        guard let outCtx else { throw RemuxError.failed("no output") }
        defer {
            if outCtx.pointee.pb != nil { avio_closep(&outCtx.pointee.pb) }
            avformat_free_context(outCtx)
        }

        // Video first, then audio; data and timed-metadata streams are dropped.
        let inputCount = Int(inCtx.pointee.nb_streams)
        let inputs = (0..<inputCount).compactMap { inCtx.pointee.streams[$0] }
        func isKept(_ stream: UnsafeMutablePointer<AVStream>, _ type: AVMediaType) -> Bool {
            stream.pointee.codecpar.pointee.codec_type == type
                && stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
        }
        let ordered = inputs.filter { isKept($0, AVMEDIA_TYPE_VIDEO) } + inputs.filter { isKept($0, AVMEDIA_TYPE_AUDIO) }
        guard ordered.contains(where: { isKept($0, AVMEDIA_TYPE_VIDEO) || isKept($0, AVMEDIA_TYPE_AUDIO) }) else {
            throw RemuxError.failed("no audio or video")
        }

        // MP4 keeps one AAC config per track, where a transport stream has a header on every
        // frame: written from what the audio really is, not copied from those headers.
        let aacPlans = format == "mp4" ? try aacConfigs(for: input) : [:]

        var mapping = [Int32](repeating: -1, count: inputCount)
        let hasDefaultAudio = ordered.contains { isKept($0, AVMEDIA_TYPE_AUDIO) && $0.pointee.disposition & AV_DISPOSITION_DEFAULT != 0 }
        var firstAudio = true
        for source in ordered {
            guard let target = avformat_new_stream(outCtx, nil) else { throw RemuxError.failed("new stream") }
            try check(avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar), "copy codec")
            target.pointee.codecpar.pointee.codec_tag = 0
            if let plan = aacPlans[Int(source.pointee.index)] {
                setExtradata(plan.fixed.bytes, on: target.pointee.codecpar)
            }
            target.pointee.time_base = source.pointee.time_base
            mapping[Int(source.pointee.index)] = target.pointee.index

            if source.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                // The HLS demuxer puts a rendition's LANGUAGE in "language" and its NAME in "comment".
                if let language = tag("language", of: source) {
                    av_dict_set(&target.pointee.metadata, "language", isoLanguage(language), 0)
                }
                if let name = tag("comment", of: source) ?? tag("title", of: source) {
                    av_dict_set(&target.pointee.metadata, "title", name, 0)
                    av_dict_set(&target.pointee.metadata, "handler_name", name, 0)
                }
                let isDefault = hasDefaultAudio ? source.pointee.disposition & AV_DISPOSITION_DEFAULT != 0 : firstAudio
                target.pointee.disposition = isDefault ? AV_DISPOSITION_DEFAULT : 0
                firstAudio = false
            } else {
                target.pointee.disposition = AV_DISPOSITION_DEFAULT
            }
        }

        if outCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&outCtx.pointee.pb, output.path, AVIO_FLAG_WRITE), "create file")
        }
        var options: OpaquePointer?
        if format == "mp4" { av_dict_set(&options, "movflags", "+faststart", 0) }
        defer { av_dict_free(&options) }
        try check(avformat_write_header(outCtx, &options), "write header")

        var allocated = av_packet_alloc()
        defer { av_packet_free(&allocated) }
        guard let packet = allocated else { throw RemuxError.failed("packet") }
        let outputCount = Int(outCtx.pointee.nb_streams)
        var lastDTS = [Int64](repeating: noPTS, count: outputCount)
        // The file starts at zero: a transport stream's clock rarely does (1.4 s, often minutes),
        // and kept as it was that's dead air before the first frame. HLS playback hid it. Every
        // stream moves by the same amount, so they stay in sync.
        let start = inCtx.pointee.start_time == noPTS ? 0 : inCtx.pointee.start_time
        var offset = (0..<outputCount).map { index in
            -av_rescale_q(start, AVRational(num: 1, den: 1_000_000), outCtx.pointee.streams[index]!.pointee.time_base)
        }

        while true {
            let read = av_read_frame(inCtx, packet)
            if read == averrorEOF { break }
            try check(read, "read")
            let sourceIndex = Int(packet.pointee.stream_index)
            guard sourceIndex < mapping.count, mapping[sourceIndex] >= 0,
                  let source = inCtx.pointee.streams[sourceIndex] else {
                av_packet_unref(packet)
                continue
            }
            // The config now says what the ADTS headers said; FFmpeg's own stripping would
            // write its config from the header again.
            if aacPlans[sourceIndex] != nil { try stripADTSHeader(packet) }
            let targetIndex = Int(mapping[sourceIndex])
            let target = outCtx.pointee.streams[targetIndex]!
            packet.pointee.stream_index = Int32(targetIndex)
            av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
            packet.pointee.pos = -1

            // A segment whose clock restarts (a discontinuity) or repeats a timestamp would make
            // MP4 refuse the packet: carry on from where the stream got to instead.
            if packet.pointee.dts != noPTS {
                var dts = packet.pointee.dts + offset[targetIndex]
                if lastDTS[targetIndex] != noPTS, dts <= lastDTS[targetIndex] {
                    let shift = lastDTS[targetIndex] + max(packet.pointee.duration, 1) - dts
                    offset[targetIndex] += shift
                    dts += shift
                }
                packet.pointee.dts = dts
                if packet.pointee.pts != noPTS { packet.pointee.pts += offset[targetIndex] }
                lastDTS[targetIndex] = dts
            } else if packet.pointee.pts != noPTS {
                packet.pointee.pts += offset[targetIndex]
            }

            try check(av_interleaved_write_frame(outCtx, packet), "write")
        }
        try check(av_write_trailer(outCtx), "finish")
    }

    struct AACPlan {
        var current: AACAudioConfig
        var fixed: AACAudioConfig
        var needsReplacing: Bool { current.needsReplacing(by: fixed) }
    }

    /// Each AAC stream's config as the file has it (its config, or its first ADTS header) and as
    /// it should be, from decoding its first frames. Keyed by input stream index.
    static func aacConfigs(for input: URL) throws -> [Int: AACPlan] {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&ctx, input.path, nil, nil), "open \(input.lastPathComponent)")
        defer { avformat_close_input(&ctx) }
        guard let ctx else { return [:] }
        try check(avformat_find_stream_info(ctx, nil), "read stream info")

        struct Probe {
            var decoder: UnsafeMutablePointer<AVCodecContext>
            var current: AACAudioConfig?
            var frames = 0
        }
        var probes: [Int: Probe] = [:]
        defer {
            for probe in probes.values {
                var decoder: UnsafeMutablePointer<AVCodecContext>? = probe.decoder
                avcodec_free_context(&decoder)
            }
        }
        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index],
                  stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_AAC,
                  let codec = avcodec_find_decoder(AV_CODEC_ID_AAC),
                  let decoder = avcodec_alloc_context3(codec) else { continue }
            let par = stream.pointee.codecpar.pointee
            let config = par.extradata_size > 0 && par.extradata != nil
                ? AACAudioConfig(audioSpecificConfig: Array(UnsafeBufferPointer(start: par.extradata, count: Int(par.extradata_size))))
                : nil
            guard avcodec_parameters_to_context(decoder, stream.pointee.codecpar) >= 0,
                  avcodec_open2(decoder, codec, nil) >= 0 else {
                var unused: UnsafeMutablePointer<AVCodecContext>? = decoder
                avcodec_free_context(&unused)
                continue
            }
            probes[index] = Probe(decoder: decoder, current: config)
        }
        guard !probes.isEmpty else { return [:] }

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        guard let packet, let frame else { return [:] }
        // A dozen decoded frames settle SBR and PS; a few hundred packets is plenty to find them.
        var read = 0
        while read < 2_000, probes.values.contains(where: { $0.frames < 12 }) {
            guard av_read_frame(ctx, packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            read += 1
            let index = Int(packet.pointee.stream_index)
            guard var probe = probes[index], probe.frames < 12 else { continue }
            if probe.current == nil, packet.pointee.size >= 7, let data = packet.pointee.data {
                probe.current = AACAudioConfig(adtsHeader: Array(UnsafeBufferPointer(start: data, count: 7)))
            }
            if avcodec_send_packet(probe.decoder, packet) >= 0 {
                while avcodec_receive_frame(probe.decoder, frame) >= 0 {
                    probe.frames += 1
                    av_frame_unref(frame)
                }
            }
            probes[index] = probe
        }

        var plans: [Int: AACPlan] = [:]
        for (index, probe) in probes {
            guard let current = probe.current, probe.frames > 0 else { continue }
            let fixed = current.explicit(decodedRate: Int(probe.decoder.pointee.sample_rate))
            plans[index] = AACPlan(current: current, fixed: fixed)
        }
        return plans
    }

    private static func setExtradata(_ bytes: [UInt8], on par: UnsafeMutablePointer<AVCodecParameters>) {
        av_freep(&par.pointee.extradata)
        let padding = 64 // AV_INPUT_BUFFER_PADDING_SIZE
        guard let buffer = av_mallocz(bytes.count + padding)?.assumingMemoryBound(to: UInt8.self) else {
            par.pointee.extradata_size = 0
            return
        }
        buffer.update(from: bytes, count: bytes.count)
        par.pointee.extradata = buffer
        par.pointee.extradata_size = Int32(bytes.count)
    }

    /// Drops a packet's ADTS header, leaving the raw frame MP4 stores. A packet without one is
    /// left alone.
    private static func stripADTSHeader(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        guard packet.pointee.size >= 7, let data = packet.pointee.data,
              let header = ADTSHeader(Array(UnsafeBufferPointer(start: data, count: 7))) else { return }
        guard header.extraRawBlocks == 0 else { throw RemuxError.failed(String(localized: "shared.aac_frames_packed_several_to")) }
        guard Int(packet.pointee.size) > header.length else { return }
        packet.pointee.data = data.advanced(by: header.length)
        packet.pointee.size -= Int32(header.length)
    }

    private static func tag(_ key: String, of stream: UnsafeMutablePointer<AVStream>) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0),
              let value = entry.pointee.value else { return nil }
        let text = String(cString: value).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// MP4 stores a track's language as a three-letter ISO 639-2 code and discards anything else,
    /// while HLS playlists usually say "en" or "ja-JP".
    static func isoLanguage(_ code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? code
        guard base.count == 2 else { return base }
        if #available(iOS 16, macOS 13, *),
           let alpha3 = Locale.Language(identifier: base).languageCode?.identifier(.alpha3) {
            return alpha3
        }
        return base
    }

    private static func check(_ result: Int32, _ step: String) throws {
        guard result < 0 else { return }
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(result, &buffer, buffer.count)
        throw RemuxError.failed("\(step): \(String(cString: buffer))")
    }
}
#endif
