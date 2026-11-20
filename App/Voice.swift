import Foundation
import AVFoundation

/// Push-to-talk voice over BLE advertising.
/// Microphone → 8 kHz → Codec2 700C (28 bits / 40 ms) → 3 frames per packet (84 bits in 11 bytes, 120 ms of speech).
/// Each packet: [sender id][seq hi][seq lo][11 bytes] = 14 bytes, the same size as a Morse packet.
/// Listeners keep a short jitter buffer per talker and play silence for packets they missed.
final class VoiceEngine {
    static let framesPerPacket = 3
    static let packetSeconds = 0.12

    /// Called on the main thread with each 14-byte packet to advertise.
    var onPacket: ((Data) -> Void)?
    /// Called on the main thread when someone starts or stops talking.
    var onTalker: ((String, Bool) -> Void)?

    private let senderId = UInt8.random(in: 0...255)
    private var seq: UInt16 = 0

    // ---- transmit ----
    private var capture: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var encoder: OpaquePointer?
    private var fifo: [Int16] = []
    private var pendingFrames: [[UInt8]] = []
    private let lock = NSLock()
    private let format8k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    // ---- receive ----
    private let playback = AVAudioEngine()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
    private var streams: [String: Stream] = [:]
    private let queue = DispatchQueue(label: "voice.rx")

    private final class Stream {
        let name: String
        let decoder: OpaquePointer
        let player = AVAudioPlayerNode()
        var buffer: [UInt16: [UInt8]] = [:]
        var next: UInt16 = 0
        var lastHeard = Date()
        var timer: DispatchSourceTimer?
        init(name: String) { self.name = name; decoder = codec2_create(CODEC2_MODE_700C) }
        deinit { codec2_destroy(decoder) }
    }

    // MARK: transmit

    func startTalking(denied: @escaping () -> Void) {
        requestMic { [weak self] ok in
            guard let self else { return }
            if ok { self.beginCapture() } else { denied() }
        }
    }

    func stopTalking() {
        capture?.inputNode.removeTap(onBus: 0)
        capture?.stop()
        capture = nil
        lock.lock()
        if let encoder { codec2_destroy(encoder) }
        encoder = nil
        fifo.removeAll(); pendingFrames.removeAll()
        lock.unlock()
    }

    private func requestMic(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { done(ok) } }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: finish)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(finish)
        }
    }

    private func beginCapture() {
        stopTalking()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: format8k) else { return }
        converter = conv
        encoder = codec2_create(CODEC2_MODE_700C)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.consume(buf)
        }
        do { try engine.start(); capture = engine } catch { stopTalking() }
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter, let encoder else { return }
        let ratio = 8000 / buf.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format8k, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16) else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard let ch = out.int16ChannelData else { return }
        fifo.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        while fifo.count >= 320 {
            var frame = Array(fifo.prefix(320)); fifo.removeFirst(320)
            var bytes = [UInt8](repeating: 0, count: 4)
            frame.withUnsafeMutableBufferPointer { s in codec2_encode(encoder, &bytes, s.baseAddress) }
            pendingFrames.append(bytes)
            if pendingFrames.count == Self.framesPerPacket {
                let packet = makePacket(pendingFrames)
                pendingFrames.removeAll()
                DispatchQueue.main.async { [weak self] in self?.onPacket?(packet) }
            }
        }
    }

    private func makePacket(_ frames: [[UInt8]]) -> Data {
        seq &+= 1
        var bits: [UInt8] = []
        for f in frames { for i in 0..<28 { bits.append((f[i / 8] >> (7 - UInt8(i % 8))) & 1) } }
        var body = [UInt8](repeating: 0, count: 11)
        for (i, b) in bits.enumerated() where b == 1 { body[i / 8] |= 1 << (7 - UInt8(i % 8)) }
        return Data([senderId, UInt8(seq >> 8), UInt8(seq & 0xff)] + body)
    }

    // MARK: receive

    func startListening() {
        if !playback.isRunning {
            _ = playback.mainMixerNode
            try? playback.start()
        }
    }

    func stopListening() {
        queue.async { [weak self] in
            guard let self else { return }
            for s in self.streams.values { s.timer?.cancel(); s.player.stop() }
            let names = self.streams.values.map(\.name)
            self.streams.removeAll()
            DispatchQueue.main.async { names.forEach { self.onTalker?($0, false) } }
        }
        playback.stop()
    }

    /// `packet` is the 14 bytes after the magic.
    func receive(_ packet: Data, from name: String, key: String) {
        let p = [UInt8](packet)
        guard p.count >= 14 else { return }
        let seq = UInt16(p[1]) << 8 | UInt16(p[2])
        let frames = Array(p[3..<14])
        queue.async { [weak self] in self?.store(key: key + "#\(p[0])", name: name, seq: seq, body: frames) }
    }

    private func store(key: String, name: String, seq: UInt16, body: [UInt8]) {
        startListening()
        var s = streams[key]
        if s == nil || Date().timeIntervalSince(s!.lastHeard) > 1.0 {
            s?.timer?.cancel()
            let fresh = Stream(name: name)
            playback.attach(fresh.player)
            playback.connect(fresh.player, to: playback.mainMixerNode, format: playFormat)
            fresh.player.play()
            fresh.next = seq
            streams[key] = fresh
            s = fresh
            startPump(fresh, key: key)
            DispatchQueue.main.async { [weak self] in self?.onTalker?(name, true) }
        }
        guard let s else { return }
        s.lastHeard = Date()
        // ignore packets that are already played or wildly out of range
        let ahead = seq &- s.next
        if ahead < 64 { s.buffer[seq] = body }
    }

    private func startPump(_ s: Stream, key: String) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.45, repeating: Self.packetSeconds, leeway: .milliseconds(5))
        t.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if Date().timeIntervalSince(s.lastHeard) > 1.0 && s.buffer.isEmpty {
                t.cancel(); s.player.stop(); self.playback.detach(s.player)
                if self.streams[key] === s { self.streams[key] = nil }
                DispatchQueue.main.async { self.onTalker?(s.name, false) }
                return
            }
            let body = s.buffer.removeValue(forKey: s.next)
            s.next &+= 1
            self.play(s, body)
        }
        s.timer = t
        t.resume()
    }

    private func play(_ s: Stream, _ body: [UInt8]?) {
        let n = 320 * Self.framesPerPacket
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(n)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        if let body {
            var pcm = [Int16](repeating: 0, count: 320)
            for f in 0..<Self.framesPerPacket {
                var frame = [UInt8](repeating: 0, count: 4)
                for i in 0..<28 {
                    let bit = f * 28 + i
                    if (body[bit / 8] >> (7 - UInt8(bit % 8))) & 1 == 1 { frame[i / 8] |= 1 << (7 - UInt8(i % 8)) }
                }
                pcm.withUnsafeMutableBufferPointer { p in codec2_decode(s.decoder, p.baseAddress, &frame) }
                for i in 0..<320 { out[f * 320 + i] = Float(pcm[i]) / 32768 * 1.6 }
            }
        } else {
            for i in 0..<n { out[i] = 0 }
        }
        s.player.scheduleBuffer(buf, completionHandler: nil)
    }
}
