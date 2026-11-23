import AVFoundation
import Foundation

@MainActor
final class SpeakerStreamer {
    /// Rebuilt on every start. `AVAudioEngine` binds its output node to the
    /// hardware format that is current when the engine is created, so an engine
    /// built at app launch (before the session category is set) stays stuck on
    /// the mono receiver route and only the bottom iPhone speaker plays.
    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var streamTask: Task<Void, Never>?
    private var client: TalkAPIClient?
    private var session = ""
    /// The receive loop of the running stream. It lives off the main actor
    /// (2026-10-24): the computer's log counted 163 waits over 80 ms in 47
    /// minutes of one episode - each one heard as a break - while a ping to
    /// the phone over the same Wi-Fi never passed 123 ms. The loop used to
    /// resume on the main actor after every request, so anything the
    /// interface was doing at that moment held the next request back.
    private var receiver: SpeakerPump?
    // A ping round trip is 3-7 ms, but a ping is not what this loop does: it
    // posts 25 requests a second over Wi-Fi, and iPhone power saving stretches
    // single exchanges far past that. 30 ms of cushion emptied on every one of
    // those, and an emptied queue pauses the player and re-prebuffers - the
    // stutter was this restart cycle, not the network. So there has to be a
    // floor under the jitter; the question is only how high.
    //
    // It was 120 ms, chosen against a 30 ms that stuttered, with nothing tried
    // in between. This is 80 ms: nearer the number that worked than the one
    // that failed, and it is heard in conversation, because this cushion is
    // pure standing delay on the computer's side of every reply. The queue
    // still drains to near zero between packets, so what this sets is the
    // depth it refills to, not a backlog it carries.
    //
    // If the stutter comes back, this is the first thing to put back - and
    // `dropped_chunks` in the speaker stop line is where it shows.
    private let prebufferFrames = 3_840
    // Only reachable if the phone is handed a full backlog and then falls
    // behind again, which the 300 ms cap on the Windows side already prevents.
    // It stays as the resync of last resort: one audible break beats drifting
    // permanently behind the computer.
    private let maxBufferedFrames = 28_800
    // The cushion above is where a stream starts and where it settles, not a
    // fixed depth (build 23, 2026-10-28). The computer's log counted 3-5
    // waits a minute past 80 ms since 2026-10-24, each one heard as a break,
    // while the computer itself answered 11,000 local requests in five
    // minutes without one over 50 ms: the waits are the Wi-Fi and the phone.
    // So a break deepens the cushion by 40 ms, up to 200 ms, and a calm
    // half minute gives 20 ms of it back. The owner's rule still holds -
    // the sound must not trail the picture - but only as far as the link
    // allows: a steady link plays at 80 ms, a stuttering one trades a little
    // delay for no breaks, and the delay is undone once it calms down.
    private let maxCushionFrames = 9_600
    private let cushionStepUp = 1_920
    private let cushionStepDown = 960
    private let calmSecondsBeforeShrinking: TimeInterval = 30
    private(set) var deviceName = ""
    private(set) var lastError = ""
    private(set) var isStreaming = false
    /// Number of channels the iPhone output route actually accepted. 2 means
    /// both built-in speakers play; 1 means the bottom speaker only.
    private(set) var outputChannelCount = 0
    var isStereoOutput: Bool { outputChannelCount >= 2 }
    /// Set while the engine belongs to the microphone, so stopping the speaker
    /// neither stops that engine nor deactivates a session it still needs.
    private var isHosted = false
    /// Make-up gain. Both modes take one; the hosted mode takes more.
    ///
    /// The first version of this gave the hosted path 2.0 and the unhosted
    /// path nothing, on the reasoning that `.playback` at full volume needs no
    /// help. Listening said otherwise, and said it backwards: with the
    /// microphone running the speaker was *louder* - the doubling works and is
    /// audible - and with it off, on `.playback`, it dropped further. So the
    /// path that was left alone was the quiet one.
    ///
    /// The level is not lost on the way, either. Measured on this machine by
    /// playing a 1 kHz tone at -3 dBFS and reading the WASAPI loopback that
    /// `speaker_source` captures: it comes back at -6.4 dBFS, so Windows gives
    /// away 3.4 dB and hands the phone a strong signal. What is quiet is the
    /// iPhone's own end of it.
    ///
    /// These are much higher than they look, and the lookahead limiter below
    /// is what makes them safe. Measured on the probe's own narration, which
    /// has a crest factor of 20.6 dB - speech spends almost all of its time
    /// far below its peaks - at a gain of 2.2 the loudest sample reached only
    /// 0.553, nowhere near any ceiling. So the old gains were not being held
    /// back by the limiter at all; they were simply too small, and every
    /// crackle heard was the probe's pure tones, never the speech.
    ///
    /// At 4.5 that narration measures 6.2 dB louder with the peak at 0.989 and
    /// not one clipped sample, because the limiter now catches peaks before
    /// they are played instead of after.
    private let hostedGain: Float = 6.0
    /// `.playback` on its own engine: the quieter path is the hosted one, so
    /// this sits below it.
    private let unhostedGain: Float = 4.5
    /// Peak the limiter is following, carried between packets.
    ///
    /// Two attempts preceded this one and each failed in its own direction.
    ///
    /// A soft knee reshaped every sample on its own. It never clipped and
    /// never overshot, and it crackled anyway, because bending a waveform
    /// inside its own cycle *is* distortion - 17% THD on the probe's 440 Hz
    /// step at a gain of 2.2.
    ///
    /// An envelope limiter without lookahead was worse on both counts, and
    /// measurably: 149 hard-clipped samples at each note onset where the knee
    /// had none, because a 1.5 ms attack cannot catch the first peak of a
    /// 2.27 ms cycle, and 1.5 dB quieter besides. The owner heard both.
    ///
    /// Looking ahead fixes the cause rather than the symptom. The audio is
    /// delayed by three milliseconds and the envelope is computed on what has
    /// *not* played yet, so the gain is already down when the peak arrives.
    /// The attack can then be instant, since nothing has to be caught in
    /// flight, and the same probe step measures 0.17% THD with no clipping.
    ///
    /// The running state (peak, hold, delay line) lives in `SpeakerPump`,
    /// one per stream; the constants stay here.
    ///
    /// Three milliseconds of delay, which is what buys the instant attack.
    /// It is longer than one cycle of the lowest tone that matters here, and
    /// invisible against the ~170 ms the reply already takes to arrive. The
    /// hold after a peak is one sample longer than this, so the sample that
    /// caused the peak is out of the line before the reduction starts easing.
    private let lookaheadLength = 144
    /// Ceiling, now that reaching it costs nothing.
    private let limiterCeiling: Float = 0.95
    /// 60 ms to let go. Faster than the 180 ms tried before, because the
    /// lookahead means release is the only time constant left to get wrong:
    /// too slow and one loud syllable ducks the sentence after it.
    private let limiterRelease: Float = 0.99972
    /// A slow leveler in front of the limiter (2026-10-24). The make-up gains
    /// above were sized on speech, whose crest factor is over 20 dB, so even
    /// at 4.5 the limiter never touched it. Film music is dense: at the same
    /// gain it came out 12.7 dB louder than speech, the limiter held it down
    /// 61% of the time and its gain swung 24 dB a second with every beat -
    /// the "pumped" sound the owner heard as stutter under background music.
    /// The leveler follows loudness over 300 ms and lowers the gain within
    /// 50 ms when the material is dense, then lets it rise back over 1.5 s.
    /// Speech never reaches the target, so it keeps its full gain (measured
    /// unchanged); music lands 3 dB above it, the limiter goes idle, and the
    /// swing falls to 1.2 dB a second. A target of 0.12 cost speech without
    /// pauses 1.3 dB, so it is 0.14. It delays nothing: the gain is
    /// computed from what has already passed, never from what is coming.
    private let levelerTarget: Float = 0.14
    private let levelerAverage: Float = 0.99993056
    private let levelerAttack: Float = 0.99958340
    private let levelerRise: Float = 0.99998611

    /// - Parameter hostEngine: the microphone's voice-processing engine, while
    ///   the iPhone is also acting as the computer microphone. Passing it is
    ///   not an optimisation: an echo canceller only removes what its own
    ///   engine renders, so playing the computer anywhere else means the
    ///   computer's own voice goes back to the computer and the model answers
    ///   itself. iOS then has to stay on `.playAndRecord`, which routes
    ///   playback to the bottom speaker only -- that is the price of it.
    ///   `nil` when the microphone is off, and the speaker owns its engine.
    func start(
        client: TalkAPIClient,
        hostEngine: AVAudioEngine? = nil
    ) async throws {
        let audioSession = AVAudioSession.sharedInstance()
        // `.playback` (never `.playAndRecord`) is what lets iOS drive both the
        // top and the bottom speaker as a stereo pair. When the microphone is
        // hosting, the session is already its own and is left alone: switching
        // to `.playback` would silently cut the capture, and re-setting the
        // category underneath a running engine only risks a route change.
        if hostEngine == nil {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try? audioSession.setPreferredSampleRate(48_000)
            try? audioSession.setPreferredIOBufferDuration(0.01)
            try audioSession.setActive(true)
            try? audioSession.setPreferredOutputNumberOfChannels(
                min(2, audioSession.maximumOutputNumberOfChannels)
            )
        }
        outputChannelCount = audioSession.outputNumberOfChannels

        let started = try await client.startSpeaker()
        guard started.sampleRate == 48_000, started.channels == 2,
              let streamFormat = AVAudioFormat(
                standardFormatWithSampleRate: Double(started.sampleRate),
                channels: AVAudioChannelCount(started.channels)
              ) else {
            try? await client.stopSpeaker(session: started.session)
            if hostEngine == nil {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw WiFiTalkError.server("صيغة صوت الكمبيوتر غير مدعومة")
        }

        isHosted = hostEngine != nil
        self.client = client
        session = started.session
        deviceName = started.device
        lastError = ""
        // Build the engine only now, so its output node adopts the stereo
        // built-in-speaker route that the session was just switched to. When
        // the microphone is hosting, its engine is already running on the voice
        // route and is only lent a player node.
        engine = hostEngine ?? AVAudioEngine()
        engine.attach(player)
        if isHosted {
            outputChannelCount = Int(engine.mainMixerNode.outputFormat(forBus: 0).channelCount)
            engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        } else {
            let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
            engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
            outputChannelCount = max(
                outputChannelCount,
                Int(hardwareFormat.channelCount)
            )
            engine.prepare()
            do {
                try engine.start()
            } catch {
                engine.disconnectNodeOutput(player)
                engine.detach(player)
                try? await client.stopSpeaker(session: started.session)
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                throw error
            }
        }
        isStreaming = true
        pump()
    }

    /// Starts the receive loop off the main actor. A fresh `SpeakerPump` per
    /// stream: the limiter starts wide open and the delay line empty, so the
    /// first words are neither ducked by the last session nor preceded by
    /// three milliseconds of it.
    private func pump() {
        guard let client, let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2
        ) else { return }
        let gain = isHosted ? hostedGain : unhostedGain
        let running = SpeakerPump(
            client: client,
            session: session,
            format: format,
            player: player,
            gain: gain,
            ceiling: limiterCeiling,
            release: limiterRelease,
            lookahead: lookaheadLength,
            levelerTarget: levelerTarget,
            levelerAverage: levelerAverage,
            levelerAttack: levelerAttack,
            levelerRise: levelerRise,
            prebufferFrames: prebufferFrames,
            maxBufferedFrames: maxBufferedFrames,
            maxCushionFrames: maxCushionFrames,
            cushionStepUp: cushionStepUp,
            cushionStepDown: cushionStepDown,
            calmSecondsBeforeShrinking: calmSecondsBeforeShrinking,
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.isStreaming else { return }
                    self.lastError = message
                    await self.stop()
                }
            }
        )
        receiver = running
        streamTask = Task.detached(priority: .userInitiated) {
            await running.run()
        }
    }

    func stop() async {
        guard isStreaming || !session.isEmpty else { return }
        isStreaming = false
        let activeSession = session
        session = ""
        // The loop is told first and waited for, so it cannot schedule a
        // buffer on a player that is about to leave the engine.
        receiver?.cancel()
        streamTask?.cancel()
        await streamTask?.value
        streamTask = nil
        receiver = nil
        player.stop()
        // A hosted engine belongs to the microphone: hand back the player node
        // and nothing else. Stopping it would cut the capture, and deactivating
        // the session would end it altogether.
        if !isHosted { engine.stop() }
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        if let client, !activeSession.isEmpty {
            try? await client.stopSpeaker(session: activeSession)
        }
        self.client = nil
        deviceName = ""
        outputChannelCount = 0
        if !isHosted {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            engine = AVAudioEngine()
        }
        isHosted = false
    }
}

/// The receive loop of one speaker stream, off the main actor (2026-10-24).
///
/// The network wait and the per-sample work run on a background task. What
/// the old loop did on the main actor - counting queued frames, pausing the
/// player when it runs dry, playing it again once the cushion refills -
/// happens on one serial queue, so a buffer finishing on the audio thread and
/// a new one arriving from the network are still handled one at a time.
/// The completion handler only ever posts to that queue asynchronously,
/// because `player.stop()` runs pending handlers on the calling thread.
private final class SpeakerPump: @unchecked Sendable {
    private let client: TalkAPIClient
    private let session: String
    private let format: AVAudioFormat
    private let player: AVAudioPlayerNode
    private let gain: Float
    private let ceiling: Float
    private let release: Float
    private let levelerTarget: Float
    private let levelerAverage: Float
    private let levelerAttack: Float
    private let levelerRise: Float
    private let prebufferFrames: Int
    private let maxBufferedFrames: Int
    private let maxCushionFrames: Int
    private let cushionStepUp: Int
    private let cushionStepDown: Int
    private let calmSecondsBeforeShrinking: TimeInterval
    private let onFailure: @Sendable (String) -> Void
    private let control = DispatchQueue(label: "WiFiTalk.speaker.control", qos: .userInteractive)

    // Touched on `control` only.
    private var running = true
    private var queuedFrames = 0
    private var playbackGeneration = 0
    private var needsPrebuffer = true
    /// The depth the player refills to before it plays, and the most the
    /// queue may hold before quiet audio is let go to catch up.
    private var cushionFrames: Int
    private var lastBreak = Date()
    private var hasPlayed = false

    // Touched by the loop only, and carried across packet boundaries.
    private var limiterPeak: Float
    private var limiterHold: Int
    private var lookaheadBuffer: [Float]
    private var lookaheadIndex: Int
    private var levelerMeanSquare: Float
    private var levelerGain: Float

    init(
        client: TalkAPIClient,
        session: String,
        format: AVAudioFormat,
        player: AVAudioPlayerNode,
        gain: Float,
        ceiling: Float,
        release: Float,
        lookahead: Int,
        levelerTarget: Float,
        levelerAverage: Float,
        levelerAttack: Float,
        levelerRise: Float,
        prebufferFrames: Int,
        maxBufferedFrames: Int,
        maxCushionFrames: Int,
        cushionStepUp: Int,
        cushionStepDown: Int,
        calmSecondsBeforeShrinking: TimeInterval,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.client = client
        self.session = session
        self.format = format
        self.player = player
        self.gain = gain
        self.ceiling = ceiling
        self.release = release
        self.levelerTarget = levelerTarget
        self.levelerAverage = levelerAverage
        self.levelerAttack = levelerAttack
        self.levelerRise = levelerRise
        self.prebufferFrames = prebufferFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maxCushionFrames = maxCushionFrames
        self.cushionStepUp = cushionStepUp
        self.cushionStepDown = cushionStepDown
        self.calmSecondsBeforeShrinking = calmSecondsBeforeShrinking
        cushionFrames = prebufferFrames
        self.onFailure = onFailure
        limiterPeak = 0
        limiterHold = 0
        lookaheadBuffer = [Float](repeating: 0, count: lookahead)
        lookaheadIndex = 0
        levelerMeanSquare = 0
        // Starts at full gain, as speech would have it; dense material pulls
        // it down within 50 ms, and the limiter covers those first ones.
        levelerGain = gain
    }

    func cancel() {
        control.sync {
            running = false
            playbackGeneration += 1
            queuedFrames = 0
            needsPrebuffer = true
        }
    }

    private var isRunning: Bool { control.sync { running } }

    /// Sent with every request, so the computer hands over a stall's backlog
    /// up to this depth and skips only what is older.
    private var cushionMilliseconds: Int {
        control.sync { cushionFrames * 1000 / Int(format.sampleRate) }
    }

    func run() async {
        while isRunning, !Task.isCancelled {
            let data: Data
            do {
                data = try await client.speakerChunk(
                    session: session,
                    cushionMilliseconds: cushionMilliseconds
                )
            } catch {
                if isRunning, !Task.isCancelled {
                    onFailure(error.localizedDescription)
                }
                return
            }
            if data.isEmpty { continue }
            guard let buffer = process(data) else { continue }
            schedule(buffer)
        }
    }

    private func process(_ data: Data) -> AVAudioPCMBuffer? {
        let inputChannels = Int(format.channelCount)
        let bytesPerSample = MemoryLayout<Float>.size
        let inputBytesPerFrame = inputChannels * bytesPerSample
        guard inputChannels == 2, data.count % inputBytesPerFrame == 0 else { return nil }
        let frameCount = data.count / inputBytesPerFrame
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = buffer.floatChannelData else { return nil }
        // Both iPhone speakers are fed the same mono sum on purpose.
        // They sit about 14 cm apart and the listener holds the phone
        // far closer than that, so playing a genuine stereo pair makes
        // the two arrivals comb-filter into each other - heard as an
        // echo, not as width. Summing first makes the pair behave as
        // one louder source, which is the only useful stereo here.
        //
        // The envelope, the leveler and the delay line all run unbroken
        // across packet boundaries, but touching a property once per
        // sample is 48000 accesses a second for nothing.
        var peak = limiterPeak
        var hold = limiterHold
        var writeIndex = lookaheadIndex
        var meanSquare = levelerMeanSquare
        var level = levelerGain
        let gain = self.gain
        let ceiling = self.ceiling
        let release = self.release
        let target = levelerTarget
        let average = levelerAverage
        let attack = levelerAttack
        let rise = levelerRise
        lookaheadBuffer.withUnsafeMutableBufferPointer { delay in
            data.withUnsafeBytes { source in
                for frame in 0..<frameCount {
                    let offset = frame * inputBytesPerFrame
                    let left = source.loadUnaligned(
                        fromByteOffset: offset,
                        as: Float.self
                    )
                    let right = source.loadUnaligned(
                        fromByteOffset: offset + bytesPerSample,
                        as: Float.self
                    )
                    let mixed = (left + right) * 0.5
                    // The leveler: loudness over 300 ms sets how much of the
                    // make-up gain this material gets. Down within 50 ms,
                    // back up over 1.5 s, never above the make-up gain.
                    meanSquare = average * meanSquare + (1 - average) * mixed * mixed
                    let wanted = min(gain, target / (meanSquare.squareRoot() + 0.000001))
                    let speed = wanted < level ? attack : rise
                    level = speed * level + (1 - speed) * wanted
                    let boosted = mixed * level
                    // Read the oldest sample out, write the newest in.
                    // What leaves here is three milliseconds behind
                    // what the envelope below is looking at.
                    let delayed = delay[writeIndex]
                    delay[writeIndex] = boosted
                    writeIndex += 1
                    if writeIndex == delay.count { writeIndex = 0 }

                    // Instant attack, because the peak it is reacting
                    // to has not been played yet; then held for the
                    // length of the delay line, and only then let go
                    // by a one-pole release.
                    //
                    // The hold is not a refinement. Without it the
                    // envelope starts falling while the sample that
                    // caused it is still inside the delay line, so
                    // the reduction applied when it finally plays is
                    // the one computed for something quieter - which
                    // measured as an overshoot past the ceiling.
                    let magnitude = abs(boosted)
                    if magnitude > peak {
                        peak = magnitude
                        // One longer than the delay line. At exactly
                        // its length the release starts on the same
                        // step the sample leaves, which measured as a
                        // 0.0004 dB overshoot - inaudible, but there
                        // is no reason to leave the boundary case in.
                        hold = delay.count + 1
                    } else if hold > 0 {
                        hold -= 1
                    } else {
                        peak = release * peak + (1 - release) * magnitude
                    }
                    // Gain reduction, not waveshaping. One number
                    // scaling the whole sample, so the cycle it sits
                    // in keeps its shape and only its size changes.
                    let reduction = peak > ceiling ? ceiling / peak : 1
                    let mono = delayed * reduction
                    channels[0][frame] = mono
                    channels[1][frame] = mono
                }
            }
        }
        limiterPeak = peak
        limiterHold = hold
        lookaheadIndex = writeIndex
        levelerMeanSquare = meanSquare
        levelerGain = level
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let scheduledFrames = Int(buffer.frameLength)
        let quiet = isQuiet(buffer)
        control.sync {
            guard running else { return }
            settleCushion()
            // More queued than the cushion means the sound is behind by the
            // difference - the cushion just shrank, or the computer's clock
            // runs a hair fast. Quiet packets are let go to catch up, so the
            // skip falls in a pause; past 100 ms over, any packet is.
            let excess = queuedFrames - cushionFrames
            if !needsPrebuffer, (excess > cushionStepUp && quiet) || excess > 4_800 {
                return
            }
            if queuedFrames > maxBufferedFrames {
                playbackGeneration += 1
                player.stop()
                queuedFrames = 0
                needsPrebuffer = true
            }
            let generation = playbackGeneration
            queuedFrames += scheduledFrames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.control.async { [weak self] in
                    guard let self, self.running, self.playbackGeneration == generation else { return }
                    self.queuedFrames = max(0, self.queuedFrames - scheduledFrames)
                    if self.queuedFrames == 0 {
                        self.player.pause()
                        self.needsPrebuffer = true
                        // The player ran dry mid-stream: a break was heard.
                        // The computer's capture never stops (it sends
                        // silence too), so this is always late delivery.
                        if self.hasPlayed {
                            self.cushionFrames = min(
                                self.maxCushionFrames,
                                self.cushionFrames + self.cushionStepUp
                            )
                            self.lastBreak = Date()
                        }
                    }
                }
            }
            if needsPrebuffer, queuedFrames >= cushionFrames {
                player.play()
                needsPrebuffer = false
                hasPlayed = true
            }
        }
    }

    /// On `control`. A calm stretch gives back one step at a time, so one
    /// lucky half minute does not undo what a bad stretch needed.
    private func settleCushion() {
        guard cushionFrames > prebufferFrames,
              Date().timeIntervalSince(lastBreak) >= calmSecondsBeforeShrinking else { return }
        cushionFrames = max(prebufferFrames, cushionFrames - cushionStepDown)
        lastBreak = Date()
    }

    /// Below -40 dBFS throughout: a pause between words, or nothing playing.
    private func isQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        for frame in 0..<Int(buffer.frameLength) where abs(samples[frame]) > 0.01 {
            return false
        }
        return true
    }
}
