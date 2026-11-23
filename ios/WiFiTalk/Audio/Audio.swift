import AVFoundation
import Speech

/// One audio session for everything: listening (speech and microphone) and playing the computer's sound.
enum AudioSession {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth, .mixWithOthers])
        try s.setActive(true)
    }
}

/// Speech to text with Apple's recognizer, on the iPhone itself when it supports the language.
@MainActor
final class SpeechListener: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var text = ""
    /// Whether the last recognition ran on this iPhone (no audio left the phone).
    @Published private(set) var onDevice = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start(locale: Locale) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AIError(String(localized: "Speech recognition is not available for this language"))
        }
        try AudioSession.activate()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        onDevice = recognizer.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = true
        request = req
        text = ""
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()
        listening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let heard { self.text = heard }
                if final || error != nil { self.stopEngine() }
            }
        }
    }

    /// Stops listening and returns what was heard.
    @discardableResult
    func finish() async -> String {
        request?.endAudio()
        stopEngine()
        try? await Task.sleep(nanoseconds: 600_000_000)   // the last words arrive just after the end
        task?.finish()
        task = nil
        request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        task?.cancel()
        task = nil
        request = nil
        stopEngine()
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        listening = false
    }
}

/// Sends this iPhone's microphone to the computer (PCM int16 mono 48 kHz), where the companion plays it into a
/// virtual audio cable that Windows apps use as a microphone.
@MainActor
final class MicSender: ObservableObject {
    @Published private(set) var running = false
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!

    func start(send: @escaping @Sendable (Data) -> Void) throws {
        stop()
        try AudioSession.activate()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: format, to: target) else { throw AIError("audio format") }
        converter = conv
        let target = self.target
        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 48000 / format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            send(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }
}

/// Plays the computer's sound (PCM int16 stereo) on this iPhone, a little behind live to ride out Wi-Fi jitter.
@MainActor
final class SpeakerPlayer: ObservableObject {
    @Published private(set) var running = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queued = 0

    func start(rate: Double) throws {
        stop()
        try AudioSession.activate()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        format = fmt
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        node.play()
        running = true
    }

    func play(_ pcm: Data) {
        guard running, let format else { return }
        let frames = pcm.count / 4
        guard frames > 0, queued < 25, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return }   // more than ~half a second queued: drop to catch up
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                ch[0][i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                ch[1][i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        queued += 1
        node.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in self?.queued -= 1 }
        }
    }

    func stop() {
        node.stop()
        if engine.isRunning { engine.stop() }
        if engine.attachedNodes.contains(node) { engine.detach(node) }
        queued = 0
        running = false
    }
}
