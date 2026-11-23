import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var address: String
    @Published var pin = ""
    @Published private(set) var token: String
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var isMainConnected = false
    @Published private(set) var isRecording = false
    /// The command button's own recording. It shares the recorder with
    /// dictation, so only one of the two can be listening at a time.
    @Published private(set) var isRecordingCommand = false
    @Published private(set) var isRunningCommand = false
    @Published var pendingCommand: PendingCommand?
    /// Files a command handed to the phone, waiting for the share sheet.
    @Published var commandDownloads: [URL] = []
    @Published private(set) var isComputerMicActive = false
    @Published private(set) var computerMicDevice = ""
    @Published private(set) var isComputerSpeakerActive = false
    @Published private(set) var computerSpeakerDevice = ""
    @Published private(set) var message = ""
    @Published private(set) var lastResult: TalkResult?
    @Published private(set) var dictationLanguage: DictationLanguage = .automatic
    /// The id alone is stored, never a copy of the provider. A copy taken
    /// at launch would keep the label it had then, and the labels arrive from
    /// the companion, so it would be wrong from the first `/health` onwards.
    @Published private(set) var transcriptionProviderID: String = TranscriptionProvider.fallback.id
    @Published private(set) var providerStatuses: [ProviderStatus] = []
    @Published private(set) var corrector: String?
    @Published private(set) var isSpeakerStereo = false
    /// The clipboard button's slots, edited in the settings and saved as typed.
    @Published var pasteSnippets: [PasteSnippet] = PasteSnippetStore.read() {
        didSet { PasteSnippetStore.save(pasteSnippets) }
    }

    private let recorder = AudioRecorder()
    private let micStreamer = MicStreamer()
    private let speakerStreamer = SpeakerStreamer()
    private let defaults = UserDefaults.standard
    private var inputTail: Task<Void, Never>?
    private var connectionFailureCount = 0
    private var mouseQueue: [MouseEvent] = []
    private var isMouseInFlight = false
    private var lastMouseErrorAt: Date?

    init() {
        address = defaults.string(forKey: "wifiTalkAddress") ?? ""
        token = defaults.string(forKey: "wifiTalkToken") ?? ""
        dictationLanguage = DictationLanguage(
            rawValue: defaults.string(forKey: "wifiTalkDictationLanguage") ?? ""
        ) ?? .automatic
        let saved = defaults.string(forKey: "wifiTalkTranscriptionProvider") ?? ""
        transcriptionProviderID = saved.isEmpty ? TranscriptionProvider.fallback.id : saved
    }

    /// Cycles automatic -> Arabic -> English. Choosing a language explicitly
    /// stops the speech model from returning a translation instead of the
    /// words that were actually spoken.
    func cycleDictationLanguage() {
        let all = DictationLanguage.allCases
        let index = all.firstIndex(of: dictationLanguage) ?? 0
        dictationLanguage = all[(index + 1) % all.count]
        defaults.set(dictationLanguage.rawValue, forKey: "wifiTalkDictationLanguage")
        switch dictationLanguage {
        case .automatic: message = "Dictation language: automatic"
        case .arabic: message = "Dictation language: Arabic only"
        case .english: message = "Dictation language: English only"
        }
    }

    /// Every provider the companion has named, or the built-in list until it
    /// has named any. This is what the picker and the small key walk.
    var knownProviders: [TranscriptionProvider] {
        providerStatuses.isEmpty
            ? TranscriptionProvider.seed
            : providerStatuses.map(\.provider)
    }

    /// The selected provider, resolved through the companion's list every
    /// time it is read, so its label is never a stale copy.
    var transcriptionProvider: TranscriptionProvider {
        knownProviders.first { $0.id == transcriptionProviderID }
            ?? TranscriptionProvider.seed.first { $0.id == transcriptionProviderID }
            ?? TranscriptionProvider.unnamed(transcriptionProviderID)
    }

    /// Steps to the next service by hand.
    ///
    /// Nothing switches provider on its own. Each service has its own free
    /// daily allowance, so this is how a dictation gets past a quota that has
    /// run out - and the badge always says which one wrote the last text.
    ///
    /// It steps through the ones the companion says are ready. With six
    /// services in the list, walking past the ones that have no key on the
    /// computer would mean several presses to reach a service that can
    /// actually answer. Before `/health` has said anything, readiness is
    /// unknown rather than false, so the whole list is walked.
    func cycleTranscriptionProvider() {
        let ready = providerStatuses.filter(\.ready).map(\.provider)
        let all = ready.isEmpty ? knownProviders : ready
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == transcriptionProviderID } ?? -1
        setTranscriptionProvider(all[(index + 1) % all.count])
    }

    func setTranscriptionProvider(_ provider: TranscriptionProvider) {
        transcriptionProviderID = provider.id
        defaults.set(provider.id, forKey: "wifiTalkTranscriptionProvider")
        if isProviderReady(provider) == false {
            message = "\(provider.fullLabel): not available"
        } else {
            message = "Dictation: \(provider.fullLabel)"
        }
    }

    /// Which services can proofread the next transcript, in the order the
    /// companion would reach for them.
    ///
    /// This row used to name one model, "GPT-OSS 120B", which stopped being
    /// the truth the moment a second service could proofread: the provider
    /// that transcribed proofreads its own text when it can, so the answer
    /// depends on which one just ran.
    var correctionProviderLabel: String {
        if let corrector, !corrector.isEmpty { return corrector }
        guard !providerStatuses.isEmpty else { return "—" }
        let able = providerStatuses.filter { $0.canCorrect && $0.ready }
        guard !able.isEmpty else { return "No proofreader ready" }
        return able.map(\.provider.shortLabel).joined(separator: " ← ")
    }

    /// `nil` while the companion has not reported its providers yet, which is
    /// also what an older companion looks like.
    func isProviderReady(_ provider: TranscriptionProvider) -> Bool? {
        guard !providerStatuses.isEmpty else { return nil }
        return providerStatuses.first { $0.id == provider.id }?.ready
    }

    var isPaired: Bool { !address.isEmpty && !token.isEmpty }
    var connectionLabel: String {
        isMainConnected ? L("Connected") : L("Not connected")
    }

    private func client(withToken: Bool = true) throws -> TalkAPIClient {
        try TalkAPIClient(address: address, token: withToken ? token : "")
    }

    /// The same companion and the same pairing, handed to the files sheet.
    func transferClient() throws -> TalkAPIClient {
        try client()
    }

    func pair() async {
        await perform {
            let response = try await self.client(withToken: false).pair(pin: self.pin)
            self.token = response.token
            self.defaults.set(self.address, forKey: "wifiTalkAddress")
            self.defaults.set(response.token, forKey: "wifiTalkToken")
            self.pin = ""
            self.message = "Connected to the computer"
        }
    }

    func checkConnection() async {
        guard isPaired else {
            isMainConnected = false
            refreshOverallConnection()
            return
        }
        do {
            let response = try await client().health()
            providerStatuses = response.providers ?? []
            corrector = response.corrector
            // A choice the companion no longer offers (Groq, removed
            // 2026-10-05) moves to its default rather than staying on a
            // service that is gone.
            if !providerStatuses.isEmpty,
               !providerStatuses.contains(where: { $0.id == transcriptionProviderID }) {
                let fallback = response.defaultProvider.flatMap { id in
                    providerStatuses.first { $0.id == id }
                } ?? providerStatuses[0]
                transcriptionProviderID = fallback.id
                defaults.set(fallback.id, forKey: "wifiTalkTranscriptionProvider")
            }
            if response.ok { markConnectionSucceeded() }
            else { markConnectionFailed() }
        } catch {
            markConnectionFailed()
        }
    }

    private func markConnectionSucceeded() {
        connectionFailureCount = 0
        isMainConnected = true
        refreshOverallConnection()
    }

    private func markConnectionFailed() {
        connectionFailureCount += 1
        if connectionFailureCount >= 3 {
            isMainConnected = false
        }
        refreshOverallConnection()
    }

    private func refreshOverallConnection() {
        isConnected = isMainConnected
    }

    /// Re-checks the link and says the answer out loud. The connection used to
    /// be a passive pill in the header; now it is a button, so a tap has to do
    /// something more than change a colour the user is already looking at.
    func reportConnection() async {
        await checkConnection()
        message = isConnected
            ? "\(connectionLabel) — \(address)"
            : "Can't reach the computer at \(address)"
    }

    func forgetPairing() {
        token = ""
        isMainConnected = false
        refreshOverallConnection()
        defaults.removeObject(forKey: "wifiTalkToken")
        Hub.companion.disconnect()
        message = ""
    }

    /// The clipboard button in the header: types a saved text into the
    /// computer's active window through the same queue as the text box, so it
    /// never goes near a model (owner, 2026-10-31).
    func pasteSnippet(_ snippet: PasteSnippet) {
        guard snippet.isFilled else { return }
        enqueueInput([.edit(backspaces: 0, inserted: snippet.text)])
        message = "Pasted: \(snippet.title)"
    }

    @discardableResult
    func queueLiveEdit(from oldValue: String, to newValue: String, modifiers: [String] = []) -> Bool {
        guard oldValue != newValue else { return false }
        let oldCharacters = Array(oldValue)
        let newCharacters = Array(newValue)
        var prefix = 0
        while prefix < oldCharacters.count,
              prefix < newCharacters.count,
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        // Everything from the first changed character to the end is resent.
        //
        // The PC does not know where this editor's caret is. The wire carries a
        // count of backspaces and the text to insert, and Windows applies both
        // at its own caret, which sits at the end of what was typed. Trimming a
        // shared suffix produced a diff that was right about the string and
        // wrong about the place: putting a fatha on the first letter of a nine
        // letter sentence sent one backspace and one letter, so the PC ate the
        // last letter of the sentence and hung the fatha on the end of it.
        // Tashkeel is where this shows, because a diacritic is by definition
        // applied to a letter that is already written and rarely the last one.
        let removedCount = oldCharacters.count - prefix
        let inserted = newCharacters.count > prefix ? String(newCharacters[prefix...]) : ""
        let insertedCharacters = Array(inserted)
        let comboMode = modifiers.contains("ctrl") || modifiers.contains("alt")
        let isCombo = comboMode
            && insertedCharacters.count == 1
            && insertedCharacters[0].asciiValue != nil
            && (insertedCharacters[0].isLetter || insertedCharacters[0].isNumber)
        var commands: [RemoteInputCommand] = []
        if modifiers.isEmpty {
            commands.append(.edit(backspaces: removedCount, inserted: inserted))
        } else {
            if removedCount > 0 {
                commands.append(.key("backspace", modifiers: modifiers, count: removedCount))
            }
            if isCombo {
                commands.append(.combo(inserted, modifiers: modifiers))
            } else {
                let parts = inserted.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if index > 0 {
                        commands.append(.key("enter", modifiers: modifiers, count: 1))
                    }
                    if !part.isEmpty {
                        commands.append(.text(String(part)))
                    }
                }
            }
        }
        enqueueInput(commands)
        return isCombo
    }

    func sendKey(_ key: String, modifiers: [String] = [], count: Int = 1) {
        enqueueInput([.key(key, modifiers: modifiers, count: count)])
    }

    func sendCombo(_ key: String, modifiers: [String]) {
        enqueueInput([.combo(key, modifiers: modifiers)])
    }

    private func enqueueInput(_ commands: [RemoteInputCommand]) {
        let previous = inputTail
        inputTail = Task { [weak self, previous] in
            _ = await previous?.result
            guard let self else { return }
            do {
                try await self.client().sendInput(commands)
                self.markConnectionSucceeded()
            } catch {
                self.markConnectionFailed()
                self.message = error.localizedDescription
            }
        }
    }

    // MARK: - Trackpad

    /// The trackpad's own path to the companion, deliberately separate from
    /// `enqueueInput`.
    ///
    /// Two reasons it does not share the keyboard queue. A stroke produces
    /// pointer packets orders of magnitude faster than a typist produces
    /// keystrokes, and behind one serial queue a single slow keystroke would
    /// stall the pointer. And when the sign-in service is paired, typing is
    /// routed to it rather than to the companion; that service types at the
    /// Windows sign-in desktop and has no pointer at all, so the mouse always
    /// speaks to the companion on 8766.
    ///
    /// Only one request is ever in flight. Whatever the finger does while it is
    /// out is folded into the next batch, so the pointer is self-clocking: it
    /// sends as fast as the network answers and no faster, and it never builds
    /// a backlog of stale movement.
    func moveCursor(dx: Double, dy: Double) {
        if case .move(let x, let y) = mouseQueue.last {
            mouseQueue[mouseQueue.count - 1] = .move(dx: x + dx, dy: y + dy)
        } else {
            mouseQueue.append(.move(dx: dx, dy: dy))
        }
        pumpMouse()
    }

    func scrollCursor(dx: Double, dy: Double) {
        if case .scroll(let x, let y) = mouseQueue.last {
            mouseQueue[mouseQueue.count - 1] = .scroll(dx: x + dx, dy: y + dy)
        } else {
            mouseQueue.append(.scroll(dx: dx, dy: dy))
        }
        pumpMouse()
    }

    func clickMouse(_ button: String, count: Int = 1) {
        mouseQueue.append(.click(button: button, count: count))
        pumpMouse()
    }

    func setMouseButton(_ button: String, down: Bool) {
        mouseQueue.append(.button(button, down: down))
        pumpMouse()
    }

    private func pumpMouse() {
        guard isPaired else {
            mouseQueue.removeAll()
            return
        }
        guard !isMouseInFlight, !mouseQueue.isEmpty else { return }
        let batch = Array(mouseQueue.prefix(64))
        mouseQueue.removeFirst(batch.count)
        isMouseInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client().sendMouse(batch)
                // Only when it would actually change: this runs many times a
                // second, and republishing an unchanged value would redraw the
                // whole screen on every packet.
                if !self.isMainConnected { self.markConnectionSucceeded() }
            } catch {
                self.reportMouseFailure(error)
            }
            self.isMouseInFlight = false
            self.pumpMouse()
        }
    }

    /// A pointer that cannot reach the computer says so once, not on every
    /// packet, and drops what it was carrying rather than replaying a stroke
    /// the user has already finished.
    private func reportMouseFailure(_ error: Error) {
        mouseQueue.removeAll()
        let now = Date()
        if let last = lastMouseErrorAt, now.timeIntervalSince(last) < 2 { return }
        lastMouseErrorAt = now
        message = "The mouse can't reach the computer: \(error.localizedDescription)"
    }

    func copyPhoneClipboardToPC() async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "The iPhone clipboard is empty"
            return
        }
        await perform {
            try await self.client().setClipboard(text)
            self.message = "Copied the iPhone clipboard to the computer"
        }
    }

    func copyPCClipboardToPhone() async {
        await perform {
            let text = try await self.client().getClipboard()
            guard !text.isEmpty else {
                self.message = "The computer clipboard is empty"
                return
            }
            UIPasteboard.general.string = text
            self.message = "Copied the computer clipboard to the iPhone"
        }
    }

    /// True while a live stream owns the audio session. Dictation then has to
    /// borrow that session rather than build its own.
    private var streamOwnsAudioSession: Bool {
        isComputerMicActive || isComputerSpeakerActive
    }

    /// A spoken command for the computer: tap, speak, tap again.
    ///
    /// The same recorder and the same transcription service as dictation, but
    /// nothing heard is typed. The computer picks the action from a closed
    /// list - screenshot, magnifier, open a named place, send or move the file
    /// selected in Explorer, and so on - and answers with the line shown here.
    ///
    /// The language is always automatic, whatever dictation is set to: a
    /// command is Arabic with English names inside it, and forcing either
    /// language would bend one of the two.
    func toggleCommand() async {
        if isRecordingCommand {
            isRecordingCommand = false
            let shared = streamOwnsAudioSession
            guard let url = await recorder.stop(keepSessionActive: shared) else {
                message = "The recording is empty or too short"
                await restoreSpeakerRouteAfterDictation()
                return
            }
            isRunningCommand = true
            defer { isRunningCommand = false }
            await perform {
                self.message = "Working on it…"
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await self.client().runCommand(
                    fileURL: url,
                    language: .automatic,
                    provider: self.transcriptionProvider
                )
                self.message = result.reply.isEmpty ? "Done" : result.reply
                self.pendingCommand = result.pending
                if !result.files.isEmpty {
                    await self.fetchCommandFiles(result.files, reply: self.message)
                }
            }
            await restoreSpeakerRouteAfterDictation()
        } else {
            guard !isRecording, !isRunningCommand else { return }
            do {
                recorder.testRecording = TestHooks.commandRecording
                try await recorder.start(sharedWithStream: streamOwnsAudioSession)
                isRecordingCommand = true
                message = "Say your command… then tap the command button again"
            } catch {
                isRecordingCommand = false
                message = error.localizedDescription
                await restoreSpeakerRouteAfterDictation()
            }
        }
    }

    /// A typed request for the assistant: the same path as a spoken command, without the recording.
    func runTypedCommand(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunningCommand else { return }
        isRunningCommand = true
        defer { isRunningCommand = false }
        await perform {
            self.message = L("Working on it…")
            let result = try await self.client().runCommand(text: text)
            self.message = result.reply.isEmpty ? L("Done") : result.reply
            self.pendingCommand = result.pending
        }
    }

    /// Brings down what a command sent to the phone, then opens the share
    /// sheet on all of it at once - the same place the files sheet hands a
    /// download to, where iOS offers Files, Photos and every other app.
    private func fetchCommandFiles(_ files: [CommandFile], reply: String) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiFiTalkDownloads", isDirectory: true)
        var fetched: [URL] = []
        for (index, file) in files.enumerated() {
            message = files.count == 1
                ? "Fetching \(file.name)…"
                : "Fetching \(index + 1) of \(files.count)…"
            do {
                let url = try await client().downloadFile(
                    file.remote, into: directory
                ) { _ in }
                fetched.append(url)
            } catch {
                message = "\(reply)\nCouldn't fetch \(file.name): \(error.localizedDescription)"
            }
        }
        if !fetched.isEmpty {
            message = reply
            commandDownloads = fetched
        }
    }

    func toggleRecording() async {
        guard !isRecordingCommand, !isRunningCommand else { return }
        if isRecording {
            isRecording = false
            let shared = streamOwnsAudioSession
            guard let url = await recorder.stop(keepSessionActive: shared) else {
                message = "The recording is empty or too short"
                await restoreSpeakerRouteAfterDictation()
                return
            }
            await perform {
                self.message = "Turning speech into text…"
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await self.client().transcribe(
                    fileURL: url,
                    language: self.dictationLanguage,
                    provider: self.transcriptionProvider
                )
                self.lastResult = result
                let served = self.knownProviders.first { $0.id == result.provider }
                    ?? self.transcriptionProvider
                self.message = result.correctionWarning == nil
                    ? "Typed on the computer · \(served.fullLabel)"
                    : "Typed the raw text (\(served.fullLabel)): proofreading failed"
            }
            await restoreSpeakerRouteAfterDictation()
        } else {
            do {
                recorder.testRecording = TestHooks.dictationRecording
                try await recorder.start(sharedWithStream: streamOwnsAudioSession)
                isRecording = true
                message = "Listening… tap Dictate again to send · \(transcriptionProvider.fullLabel)"
            } catch {
                isRecording = false
                message = error.localizedDescription
                await restoreSpeakerRouteAfterDictation()
            }
        }
    }

    /// Rebuild the speaker stream once dictation is done with the session.
    ///
    /// Recording forces `.playAndRecord`, which routes playback to the bottom
    /// speaker alone. Simply setting `.playback` back does not undo that:
    /// `AVAudioEngine` bound its output to the channel count it was built with,
    /// so the top speaker only returns when the stream is built again. Skipped
    /// while the computer microphone is running, because that path is meant to
    /// stay on `.playAndRecord` anyway.
    private func restoreSpeakerRouteAfterDictation() async {
        guard isComputerSpeakerActive, !isComputerMicActive else { return }
        let restored = message
        await speakerStreamer.stop()
        do {
            try await speakerStreamer.start(client: client(), hostEngine: nil)
            isSpeakerStereo = speakerStreamer.isStereoOutput
            computerSpeakerDevice = speakerStreamer.deviceName
            message = restored
        } catch {
            isComputerSpeakerActive = false
            computerSpeakerDevice = ""
            isSpeakerStereo = false
            message = "Computer sound stopped after dictation: \(error.localizedDescription)"
        }
    }

    /// Put the computer speaker back on whichever engine is now the right one.
    ///
    /// The echo canceller subtracts only what its own engine renders, so the
    /// two streams cannot sit on separate engines: the computer's own voice
    /// would reach the microphone uncancelled and go straight back, and a model
    /// listening at the other end would take its own reply for an answer. So
    /// whichever side is switched second, the speaker is rebuilt on the engine
    /// that matches: the microphone's while it runs, its own once it stops.
    private func rebuildSpeakerStream() async {
        guard isComputerSpeakerActive else { return }
        await speakerStreamer.stop()
        do {
            try await speakerStreamer.start(
                client: client(),
                hostEngine: micStreamer.voiceProcessingEngine
            )
            isSpeakerStereo = speakerStreamer.isStereoOutput
            computerSpeakerDevice = speakerStreamer.deviceName
        } catch {
            isComputerSpeakerActive = false
            computerSpeakerDevice = ""
            isSpeakerStereo = false
            message = "Computer sound stopped: \(error.localizedDescription)"
        }
    }

    func toggleComputerMic() async {
        if isComputerMicActive {
            // The speaker is riding on the microphone's engine; take it off
            // before that engine goes away, and put it back on its own after.
            if isComputerSpeakerActive { await speakerStreamer.stop() }
            await micStreamer.stop(keepSessionActive: false)
            isComputerMicActive = false
            computerMicDevice = ""
            message = micStreamer.lastError.isEmpty
                ? "Computer microphone stopped"
                : "Microphone stopped: \(micStreamer.lastError)"
            await rebuildSpeakerStream()
            return
        }
        await perform {
            if self.isComputerSpeakerActive { await self.speakerStreamer.stop() }
            try await self.micStreamer.start(client: self.client()) { [weak self] status, connected in
                guard let self else { return }
                self.isComputerMicActive = true
                if connected { self.markConnectionSucceeded() }
                self.message = status
            }
            self.isComputerMicActive = true
            self.computerMicDevice = self.micStreamer.deviceName
            self.message = "The iPhone is now the computer's microphone, with voice processing"
        }
        await rebuildSpeakerStream()
    }

    func toggleComputerSpeaker() async {
        if isComputerSpeakerActive {
            await speakerStreamer.stop()
            isComputerSpeakerActive = false
            computerSpeakerDevice = ""
            isSpeakerStereo = false
            message = "Computer sound stopped"
            return
        }
        await perform {
            try await self.speakerStreamer.start(
                client: self.client(),
                hostEngine: self.micStreamer.voiceProcessingEngine
            )
            self.isComputerSpeakerActive = true
            self.computerSpeakerDevice = self.speakerStreamer.deviceName
            self.isSpeakerStereo = self.speakerStreamer.isStereoOutput
            self.message = self.speakerStreamer.isStereoOutput
                ? "Computer sound is playing on the iPhone's top and bottom speakers"
                : "Computer sound is playing on the bottom speaker only, because the iPhone microphone is on"
        }
    }

    func power(_ action: String) async {
        await perform {
            try await self.client().power(action)
            self.message = action == "restart" ? "Restarting the computer…" : "Shutting down the computer…"
        }
    }

    /// The owner's yes or no to what the companion understood.
    func answerPendingCommand(approve: Bool) async {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        await perform {
            let result = try await self.client().answerCommand(id: pending.id, approve: approve)
            self.message = result.reply.isEmpty ? "Done" : result.reply
            if !result.files.isEmpty {
                await self.fetchCommandFiles(result.files, reply: self.message)
            }
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            markConnectionSucceeded()
        } catch {
            markConnectionFailed()
            message = error.localizedDescription
        }
    }
}
