import AVFoundation
import Foundation

@MainActor
final class MicStreamer: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var deviceName = ""
    private var engine = AVAudioEngine()
    private var client: TalkAPIClient?
    private var pendingChunks: [Data] = []
    private var senderTask: Task<Void, Never>?
    private var nextSequence = 0
    private var sentSampleCount = 0
    private var manualStopRequested = false
    private var statusHandler: ((String, Bool) -> Void)?
    private(set) var lastError = ""
    private let maximumPendingChunks = 180
    /// Taps per HTTP request while the sender is keeping up.
    ///
    /// This was 5, and the log says what that cost: `bytes/chunks` across every
    /// session on record is 19200 bytes, exactly 100 ms of audio, so the first
    /// tap in each request waited 80 ms for four more before anything left the
    /// phone. Two taps is 40 ms, and the 60 ms saved is pure head start - the
    /// request count doubles but each one is half the size.
    private let chunksPerPacket = 2
    /// Taps per request once the sender has fallen behind. A backlog is already
    /// late, so the packet it travels in cannot make it later; sending it in
    /// bigger pieces is how the queue is emptied in fewer round trips.
    private let catchUpChunksPerPacket = 8

    /// The engine that carries voice processing, lent to the speaker while both
    /// run. `nil` while the microphone is off.
    ///
    /// `setVoiceProcessingEnabled` cancels the echo of what *its own* engine
    /// renders, and nothing else. While the computer's audio played through a
    /// second engine this one rendered silence, so the canceller had nothing to
    /// subtract: the computer's voice reached the microphone uncancelled and
    /// came straight back to the computer, which is how a model ends up
    /// answering itself. Playing the computer through this engine is what gives
    /// the canceller the reference signal it is asked to remove.
    var voiceProcessingEngine: AVAudioEngine? { isStreaming ? engine : nil }

    private func requirePermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw WiFiTalkError.server("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone › WiFiTalk")
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            if !granted {
                throw WiFiTalkError.server("WiFiTalk wasn't allowed to use the microphone")
            }
        @unknown default:
            throw WiFiTalkError.server("Couldn't check microphone access")
        }
    }

    func start(
        client: TalkAPIClient,
        onStatus: @escaping (String, Bool) -> Void
    ) async throws {
        try await requirePermission()
        let session = AVAudioSession.sharedInstance()
        // `.videoChat`, not `.voiceChat`, and the difference is the one the
        // owner hears. Both carry the echo canceller this duplex mode cannot do
        // without, but `.voiceChat` is the handset mode: iOS puts its output on
        // the call volume channel, whose ceiling is well under the media one and
        // which the volume buttons do not raise while media is what is playing,
        // and it voices the earpiece rather than the loudspeaker. `.videoChat`
        // is calibrated for a phone held at arm's length on speaker, which is
        // exactly how the computer's audio is being listened to here.
        try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        // Rebuilt here, after the session is active, for the same reason the
        // speaker engine is: an engine binds its output node to the route that
        // existed when it was created. This engine renders the computer's audio
        // as well as capturing the room, and an output bound to a stale route
        // would hand the echo canceller a reference that is not what is
        // actually playing.
        engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = true
        // Realise the main mixer here, while the graph is still cold. The first
        // touch of `mainMixerNode` is what creates it and wires it to the
        // output, and that settles the engine's own format; reading the input
        // format and hanging a tap on it first would mean both were chosen
        // against a graph that is about to change underneath them. The speaker
        // attaches its player to this same mixer later.
        _ = engine.mainMixerNode
        let format = input.outputFormat(forBus: 0)
        guard Int(format.sampleRate.rounded()) == 48_000 else {
            try? input.setVoiceProcessingEnabled(false)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw WiFiTalkError.server("The iPhone microphone isn't running at 48 kHz. Disconnect Bluetooth headphones and try again")
        }

        // 960 frames is 20 ms at 48 kHz, which is both the IO buffer asked for
        // above and what the log says iOS has been handing over all along: every
        // recorded packet is a whole number of 960-frame taps, never of 2048.
        // The old 2048 was a request the system ignored, so it documented a
        // chunk size that never existed.
        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            let data = Data(bytes: channel, count: frames * MemoryLayout<Float>.size)
            Task { @MainActor [weak self] in
                self?.appendChunk(data)
            }
        }
        pendingChunks.removeAll(keepingCapacity: true)
        nextSequence = 0
        sentSampleCount = 0
        manualStopRequested = false
        lastError = ""
        statusHandler = onStatus
        engine.prepare()
        var remoteStarted = false
        do {
            let started = try await client.startMic(sampleRate: 48_000, voiceProcessing: true)
            remoteStarted = true
            guard started.voiceProcessing == true else {
                throw WiFiTalkError.server("Update WiFiTalk on the computer first")
            }
            deviceName = started.device
            self.client = client
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            if remoteStarted { try? await client.stopMic() }
            self.client = nil
            statusHandler = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isStreaming = true
    }

    private func appendChunk(_ data: Data) {
        guard client != nil else { return }
        if pendingChunks.count >= maximumPendingChunks {
            pendingChunks.removeFirst()
            statusHandler?("The microphone is still on, but the connection is behind; reconnecting", false)
        }
        pendingChunks.append(data)
        guard senderTask == nil else { return }
        senderTask = Task { [weak self] in
            guard let self else { return }
            await self.drainChunks()
        }
    }

    private func drainChunks() async {
        while !Task.isCancelled, let client, !pendingChunks.isEmpty {
            let behind = pendingChunks.count > chunksPerPacket
            let chunkCount = min(
                behind ? catchUpChunksPerPacket : chunksPerPacket,
                pendingChunks.count
            )
            let chunks = Array(pendingChunks.prefix(chunkCount))
            pendingChunks.removeFirst(chunkCount)
            var data = Data(capacity: chunks.reduce(0) { $0 + $1.count })
            for chunk in chunks { data.append(chunk) }
            let sampleCount = data.count / MemoryLayout<Float>.size
            var sequence = nextSequence
            var sampleOffset = sentSampleCount
            var failures = 0
            while !Task.isCancelled {
                do {
                    try await client.sendMicChunk(
                        data,
                        sequence: sequence,
                        sampleOffset: sampleOffset,
                        sampleCount: sampleCount
                    )
                    nextSequence = sequence + 1
                    sentSampleCount = sampleOffset + sampleCount
                    if failures > 0 {
                        lastError = ""
                        statusHandler?("The microphone is connected to the computer again", true)
                    }
                    // Nothing is slept here on purpose. A backlog used to pause
                    // the sender for 125 ms, which is six new 20 ms taps
                    // arriving while five were being cleared: the one state the
                    // queue could never leave was the one state that needed
                    // leaving. Only one request is ever in flight - the await
                    // above is the throttle - so the answer to falling behind
                    // is the larger packet above, and then straight back round.
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    lastError = error.localizedDescription
                    failures += 1
                    statusHandler?("The microphone is still on; reconnecting to the computer: \(lastError)", false)
                    if manualStopRequested { break }
                    if failures.isMultiple(of: 3) {
                        do {
                            let started = try await client.startMic(
                                sampleRate: 48_000,
                                voiceProcessing: true
                            )
                            guard started.voiceProcessing == true else {
                                throw WiFiTalkError.server("The computer's WiFiTalk doesn't support this microphone mode")
                            }
                            deviceName = started.device
                            nextSequence = 0
                            sentSampleCount = 0
                            sequence = 0
                            sampleOffset = 0
                        } catch {
                            lastError = error.localizedDescription
                        }
                    }
                    let delay = min(2_000_000_000, UInt64(failures) * 250_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
            if manualStopRequested && failures > 0 { break }
        }
        senderTask = nil
    }

    /// - Parameter keepSessionActive: `true` while the computer speaker is still
    ///   playing through the same audio session, so it is not torn down here.
    func stop(keepSessionActive: Bool = false) async {
        manualStopRequested = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let activeSender = senderTask
        _ = await activeSender?.result
        senderTask = nil
        pendingChunks.removeAll(keepingCapacity: true)
        if let client { try? await client.stopMic() }
        self.client = nil
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isStreaming = false
        deviceName = ""
        statusHandler = nil
        if !keepSessionActive {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
