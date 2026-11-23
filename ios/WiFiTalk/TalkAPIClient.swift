import AVFoundation
import Foundation
import Speech

/// The app's way to the computer, with the same calls the screens have always used.
///
/// Behind it there is no HTTP server and no AI on the computer: one TCP connection to the small WiFiTalk companion
/// (`Companion`), which only executes plain actions. Everything that needs understanding happens here on the
/// iPhone: speech is turned into text by Apple's recognizer (on the device when it supports the language), and
/// the text is understood or proofread by `FirebaseHybrid` (Apple's on-device model first, Gemini through
/// Firebase AI Logic in the cloud otherwise).
struct TalkAPIClient: Sendable {
    let address: String
    let token: String

    init(address: String, token: String = "") throws {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WiFiTalkError.invalidAddress }
        self.address = normalized
        self.token = token
    }

    @MainActor
    private func companion() async throws -> Companion {
        guard !token.isEmpty else { throw WiFiTalkError.notPaired }
        return try await Hub.ensure(address: address, token: token)
    }

    // MARK: pairing and health

    @MainActor
    func pair(pin: String) async throws -> PairResponse {
        let token = try await Hub.companion.connect(address: address, pin: pin, token: nil)
        Hub.address = address
        if case .connected(let name) = Hub.companion.state { return PairResponse(token: token, name: name) }
        return PairResponse(token: token, name: "PC")
    }

    @MainActor
    func health() async throws -> HealthResponse {
        let c = try await companion()
        try await c.run([["t": "ping"]])
        var name = "PC"
        if case .connected(let n) = c.state { name = n }
        return HealthResponse(ok: true, name: name, apiKeyReady: true,
                              providers: TranscriptionProvider.statuses, defaultProvider: TranscriptionProvider.fallback.id,
                              corrector: nil)
    }

    // MARK: voice: dictation and commands, understood on the phone

    /// Dictation: Apple speech to text, then (with the AI key on) a light proofreading by the hybrid model,
    /// then typed on the computer.
    @MainActor
    func transcribe(fileURL: URL, language: DictationLanguage = .automatic,
                    provider: TranscriptionProvider = .fallback, inject: Bool = true) async throws -> TalkResult {
        let heard = try await SpeechText.transcribe(fileURL, language: language)
        guard !heard.text.isEmpty else { throw WiFiTalkError.server("I didn't hear any clear words") }
        var corrected = heard.text
        var warning: String?
        var corrector: String?
        if provider.id == "ai" {
            do {
                let reply = try await FirebaseHybrid.shared.respond(system: Self.proofreadPrompt, prompt: heard.text,
                                                                    json: false, temperature: 0)
                let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                // a reply much longer than what was said is an answer, not a correction: keep the words as heard
                if !clean.isEmpty, clean.count <= heard.text.count * 2 + 20 { corrected = clean }
                corrector = EngineLabel.current
            } catch {
                warning = error.localizedDescription
            }
        }
        if inject { try await companion().run([["t": "text", "s": corrected + " "]]) }
        return TalkResult(rawText: heard.text, correctedText: corrected, correctionWarning: warning,
                          language: heard.locale, rawScript: nil,
                          provider: provider.id, correctionProvider: corrector)
    }

    /// A spoken command: Apple speech to text, then the hybrid assistant turns it into actions the computer runs.
    /// Shutting down, restarting or sleeping waits for the user's yes.
    @MainActor
    func runCommand(fileURL: URL, language: DictationLanguage = .automatic,
                    provider: TranscriptionProvider = .fallback) async throws -> CommandResult {
        let heard = try await SpeechText.transcribe(fileURL, language: language)
        guard !heard.text.isEmpty else { throw WiFiTalkError.server("I didn't hear a clear command") }
        return try await runCommand(text: heard.text)
    }

    @MainActor
    func runCommand(text: String) async throws -> CommandResult {
        let plan = try await Assistant.plan(for: text)
        let engine = EngineLabel.current
        if plan.actions.isEmpty {
            return CommandResult(ok: true, heard: text, reply: plan.say.isEmpty ? L("I didn't understand that") : plan.say,
                                 files: [], provider: engine, unlock: nil, pending: nil)
        }
        if plan.needsConfirmation {
            let id = UUID().uuidString
            Hub.pending[id] = plan
            return CommandResult(ok: true, heard: text, reply: plan.say, files: [], provider: engine, unlock: nil,
                                 pending: PendingCommand(id: id, text: plan.actions.map(Assistant.describe).joined(separator: "\n"),
                                                         seconds: nil))
        }
        try await run(plan)
        let reply = (plan.say.isEmpty ? L("Done") : plan.say) + " · " + engine
        return CommandResult(ok: true, heard: text, reply: reply, files: [], provider: engine, unlock: nil, pending: nil)
    }

    @MainActor
    func answerCommand(id: String, approve: Bool) async throws -> CommandResult {
        guard let plan = Hub.pending.removeValue(forKey: id) else {
            return CommandResult(ok: false, heard: "", reply: L("That command has expired"), files: [], provider: nil, unlock: nil, pending: nil)
        }
        guard approve else {
            return CommandResult(ok: true, heard: "", reply: L("Cancelled"), files: [], provider: nil, unlock: nil, pending: nil)
        }
        try await run(plan)
        return CommandResult(ok: true, heard: "", reply: plan.say.isEmpty ? L("Done") : plan.say, files: [], provider: nil, unlock: nil, pending: nil)
    }

    /// One action at a time, so a failure stops the rest.
    @MainActor
    private func run(_ plan: Assistant.Plan) async throws {
        let c = try await companion()
        for action in plan.actions { try await c.run([action]) }
    }

    static let proofreadPrompt = """
    You proofread dictated text. Fix punctuation, capitalization and obvious speech-recognition mistakes only.
    Keep the same language, words and meaning. Never translate, answer, explain or add anything.
    Reply with the corrected text only.
    """

    // MARK: keyboard and mouse

    @MainActor
    func sendText(_ text: String) async throws {
        try await companion().run([["t": "text", "s": text]])
    }

    @MainActor
    func sendEdit(backspaces: Int, inserted: String) async throws {
        var actions: [[String: Any]] = Array(repeating: ["t": "keys", "k": "backspace"], count: max(0, backspaces))
        if !inserted.isEmpty { actions.append(["t": "text", "s": inserted]) }
        guard !actions.isEmpty else { return }
        try await companion().run(actions)
    }

    @MainActor
    func sendKey(_ key: String, modifiers: [String] = [], count: Int = 1) async throws {
        let combo = (modifiers + [key]).joined(separator: "+")
        try await companion().run(Array(repeating: ["t": "keys", "k": combo], count: max(1, min(count, 50))))
    }

    @MainActor
    func sendCombo(_ key: String, modifiers: [String]) async throws {
        try await companion().run([["t": "keys", "k": (modifiers + [key.lowercased()]).joined(separator: "+")]])
    }

    @MainActor
    func sendInput(_ commands: [RemoteInputCommand]) async throws {
        for command in commands {
            switch command {
            case .edit(let backspaces, let inserted): try await sendEdit(backspaces: backspaces, inserted: inserted)
            case .text(let text): try await sendText(text)
            case .key(let key, let modifiers, let count): try await sendKey(key, modifiers: modifiers, count: count)
            case .combo(let key, let modifiers): try await sendCombo(key, modifiers: modifiers)
            }
        }
    }

    /// One trackpad batch, without waiting for an answer (the companion answers only a failure).
    @MainActor
    func sendMouse(_ events: [MouseEvent]) async throws {
        try await companion().send(events.map(\.payload))
    }

    @MainActor
    func setClipboard(_ text: String) async throws {
        try await companion().run([["t": "clip", "s": text]])
    }

    @MainActor
    func getClipboard() async throws -> String {
        try await companion().run([["t": "getclip"]])["clip"] as? String ?? ""
    }

    @MainActor
    func power(_ action: String) async throws {
        try await companion().run([["t": "power", "s": action]])
    }

    // MARK: the shared folder (Downloads\WiFiTalk on the computer)

    @MainActor
    func listFiles(_ relative: String = "") async throws -> RemoteFileListing {
        let reply = try await companion().run([["t": "ls", "s": relative]])
        guard let listing = reply["listing"],
              let data = try? JSONSerialization.data(withJSONObject: listing),
              let decoded = try? JSONDecoder().decode(RemoteFileListing.self, from: data) else {
            throw WiFiTalkError.invalidResponse
        }
        return decoded
    }

    @MainActor
    func downloadFile(_ file: RemoteFile, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: target)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        let c = try await companion()
        var received = 0
        let total = max(1, file.size)
        c.onFileChunk = { data in
            handle.write(data)
            received += data.count
            progress(min(1, Double(received) / Double(total)))
        }
        defer { c.onFileChunk = nil; try? handle.close() }
        try await c.run([["t": "get", "s": file.path]])
        return target
    }

    @MainActor
    func uploadFile(at fileURL: URL, name: String, subpath: String = "",
                    progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedFile {
        let c = try await companion()
        try await c.run([["t": "put", "s": name, "sub": subpath]])
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let total = max(1, (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 1)
        var sent = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try await c.sendFileChunk(chunk)
            sent += chunk.count
            progress(min(1, Double(sent) / Double(total)))
        }
        let reply = try await c.run([["t": "putend"]])
        guard let file = reply["file"] as? [String: Any] else { throw WiFiTalkError.invalidResponse }
        return UploadedFile(ok: true, name: file["name"] as? String ?? name, path: file["path"] as? String ?? name,
                            size: (file["size"] as? NSNumber)?.intValue ?? sent)
    }

    // MARK: the phone as the computer's microphone, the computer's sound on the phone

    @MainActor
    func startMic(sampleRate: Int, voiceProcessing: Bool) async throws -> MicStartResult {
        do {
            let reply = try await companion().run([["t": "mic", "on": true]])
            return MicStartResult(ok: true, device: reply["device"] as? String ?? "CABLE Input", channels: 1,
                                  sampleRate: 48_000, voiceProcessing: true)
        } catch {
            if error.localizedDescription == "no_virtual_cable" {
                throw WiFiTalkError.server("To use the iPhone as the computer's microphone, install the free VB-CABLE driver on the computer, then restart WiFiTalk there")
            }
            throw error
        }
    }

    /// float32 mono 48 kHz, as the microphone streamer has always produced it.
    @MainActor
    func sendMicChunk(_ data: Data, sequence: Int, sampleOffset: Int, sampleCount: Int) async throws {
        try await companion().sendMicrophone(data)
    }

    @MainActor
    func stopMic() async throws {
        try await companion().run([["t": "mic", "on": false]])
    }

    @MainActor
    func startSpeaker() async throws -> SpeakerStartResult {
        Hub.speakerAudio.clear()
        try await companion().run([["t": "speaker", "on": true]])
        return SpeakerStartResult(ok: true, session: "tcp", device: "Windows", sampleRate: 48_000, channels: 2)
    }

    /// The computer's sound arrives on its own as it plays (float32 stereo 48 kHz); this hands over what came,
    /// or nothing after a quiet moment.
    func speakerChunk(session: String, cushionMilliseconds: Int) async throws -> Data {
        await Hub.speakerAudio.next(timeout: 1.0)
    }

    @MainActor
    func stopSpeaker(session: String) async throws {
        try await companion().run([["t": "speaker", "on": false]])
        Hub.speakerAudio.clear()
    }
}

/// The one connection to the companion, shared by every screen.
@MainActor
enum Hub {
    static let companion: Companion = {
        let c = Companion()
        c.onSpeakerAudio = { Hub.speakerAudio.push($0) }
        return c
    }()
    static var address = ""
    static var pending: [String: Assistant.Plan] = [:]
    nonisolated static let speakerAudio = ChunkQueue()

    static func ensure(address: String, token: String) async throws -> Companion {
        var waited = 0
        while case .connecting = companion.state, waited < 100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if companion.isConnected && self.address == address { return companion }
        _ = try await companion.connect(address: address, pin: nil, token: token)
        self.address = address
        return companion
    }
}

/// Which engine understood the last request, for the line under it.
@MainActor
enum EngineLabel {
    static var current: String {
        switch FirebaseHybrid.shared.lastEngine {
        case .onDevice: return L("on this iPhone (Apple model)")
        case .cloud: return L("Gemini in the cloud (Firebase AI Logic)")
        case nil: return ""
        }
    }
}

/// Computer sound waiting for the speaker streamer: pushed by the connection, pulled by the streamer.
final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    private var waiter: (id: Int, c: CheckedContinuation<Data, Never>)?
    private var nextID = 0

    func push(_ data: Data) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.c.resume(returning: data)
            return
        }
        items.append(data)
        if items.count > 250 { items.removeFirst(items.count - 250) }
        lock.unlock()
    }

    func next(timeout: Double) async -> Data {
        await withCheckedContinuation { (c: CheckedContinuation<Data, Never>) in
            lock.lock()
            if !items.isEmpty {
                var all = Data()
                for item in items { all.append(item) }
                items.removeAll()
                lock.unlock()
                c.resume(returning: all)
                return
            }
            if let old = waiter { old.c.resume(returning: Data()) }
            nextID += 1
            let id = nextID
            waiter = (id, c)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let w = self.waiter, w.id == id {
                    self.waiter = nil
                    self.lock.unlock()
                    w.c.resume(returning: Data())
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
}

/// Apple's speech recognizer on a recorded file, on the iPhone itself when it supports the language.
enum SpeechText {
    struct Heard { let text: String; let locale: String; let onDevice: Bool }

    private final class Once: @unchecked Sendable { var done = false }

    static func locale(for language: DictationLanguage) -> Locale {
        switch language {
        case .arabic: return Locale(identifier: "ar-SA")
        case .english: return Locale(identifier: "en-US")
        case .automatic:
            let first = Locale.preferredLanguages.first ?? "en-US"
            return Locale(identifier: first.hasPrefix("ar") ? "ar-SA" : (first.hasPrefix("en") ? first : "en-US"))
        }
    }

    static func transcribe(_ url: URL, language: DictationLanguage) async throws -> Heard {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let ok = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
            guard ok else { throw WiFiTalkError.server("Allow Speech Recognition for WiFiTalk in Settings") }
        }
        let loc = locale(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: loc), recognizer.isAvailable else {
            throw WiFiTalkError.server("Speech recognition isn't available for this language right now")
        }
        if recognizer.supportsOnDeviceRecognition {
            do {
                let text = try await recognize(url, with: recognizer, onDevice: true)
                return Heard(text: text, locale: loc.identifier, onDevice: true)
            } catch {
                // the on-device model may be missing or still downloading: Apple's servers do it instead
            }
        }
        let text = try await recognize(url, with: recognizer, onDevice: false)
        return Heard(text: text, locale: loc.identifier, onDevice: false)
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        let once = Once()
        let text: String = try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: request) { result, error in
                if once.done { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    once.done = true
                    // "no speech detected" is an empty result, not a failure
                    if (error as NSError).code == 1110 { c.resume(returning: "") } else { c.resume(throwing: error) }
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
