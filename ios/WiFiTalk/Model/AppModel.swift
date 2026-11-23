import Foundation
import SwiftUI

/// The app's state: the pairing, the assistant's last request and plan, and the audio switches.
@MainActor
final class AppModel: ObservableObject {
    let link = Companion()
    let listener = SpeechListener()
    let mic = MicSender()
    let speaker = SpeakerPlayer()

    private let defaults = UserDefaults.standard
    @Published var address: String { didSet { defaults.set(address, forKey: "address") } }
    @Published private var token: String { didSet { defaults.set(token, forKey: "token") } }
    /// "auto" follows the phone's language; "en" or "ar" fixes the language the user speaks.
    @Published var speechLanguage: String { didSet { defaults.set(speechLanguage, forKey: "speechLanguage") } }

    @Published var busy = false
    @Published var request = ""
    @Published var plan: Assistant.Plan?
    @Published var planEngine: FirebaseHybrid.Engine?
    @Published var done = 0
    @Published var message: String?
    @Published var pendingConfirmation: Assistant.Plan?

    var isPaired: Bool { !address.isEmpty && !token.isEmpty }

    init() {
        address = UserDefaults.standard.string(forKey: "address") ?? ""
        token = UserDefaults.standard.string(forKey: "token") ?? ""
        speechLanguage = UserDefaults.standard.string(forKey: "speechLanguage") ?? "auto"
        link.onSpeakerFormat = { [weak self] rate in
            guard let self else { return }
            try? self.speaker.start(rate: rate)
        }
        link.onSpeakerAudio = { [weak self] pcm in self?.speaker.play(pcm) }
    }

    // MARK: pairing

    func pair(address: String, pin: String) async {
        message = nil
        do {
            let newToken = try await link.connect(address: address, pin: pin, token: nil)
            self.address = address.trimmingCharacters(in: .whitespaces)
            token = newToken
        } catch {
            message = error.localizedDescription
        }
    }

    func reconnect() async {
        guard isPaired, !link.isConnected else { return }
        if case .connecting = link.state { return }
        do {
            token = try await link.connect(address: address, pin: nil, token: token)
        } catch {
            if link.unpaired { forget() }
        }
    }

    func forget() {
        stopAudio()
        link.disconnect()
        token = ""
    }

    // MARK: the assistant

    var speechLocale: Locale {
        switch speechLanguage {
        case "en": return Locale(identifier: "en-US")
        case "ar": return Locale(identifier: "ar-SA")
        default:
            let code = Locale.preferredLanguages.first ?? "en-US"
            return Locale(identifier: code.hasPrefix("ar") ? "ar-SA" : code)
        }
    }

    func startListening() async {
        message = nil
        guard await SpeechListener.authorize() else {
            message = String(localized: "Allow the microphone and speech recognition in Settings to talk to your computer.")
            return
        }
        if mic.running { mic.stop() }
        do { try listener.start(locale: speechLocale) } catch { message = error.localizedDescription }
    }

    /// Stops listening; in command mode the words go to the assistant, in dictation mode they are typed as is.
    func finishListening(dictate: Bool) async {
        let words = await listener.finish()
        guard !words.isEmpty else { return }
        if dictate { await type(words + " ") } else { request = words; await ask(words) }
    }

    func ask(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true; message = nil; plan = nil; planEngine = nil; done = 0
        defer { busy = false }
        do {
            let p = try await Assistant.plan(for: text)
            plan = p
            planEngine = FirebaseHybrid.shared.lastEngine
            if p.needsConfirmation { pendingConfirmation = p } else { await execute(p) }
        } catch {
            message = error.localizedDescription
        }
    }

    func execute(_ p: Assistant.Plan) async {
        pendingConfirmation = nil
        do {
            // one action at a time, so the phone shows the progress and a failure stops the rest
            for action in p.actions {
                try await link.run([action])
                done += 1
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: direct control

    func type(_ text: String) async {
        do { try await link.run([["t": "text", "s": text]]) } catch { message = error.localizedDescription }
    }

    func keys(_ combo: String) {
        Task { do { try await link.run([["t": "keys", "k": combo]]) } catch { message = error.localizedDescription } }
    }

    func power(_ what: String) {
        Task { do { try await link.run([["t": "power", "s": what]]) } catch { message = error.localizedDescription } }
    }

    // MARK: audio

    func setSpeaker(_ on: Bool) {
        Task {
            do {
                try await link.run([["t": "speaker", "on": on]])
                if !on { speaker.stop() }
            } catch { message = error.localizedDescription }
        }
    }

    func setMic(_ on: Bool) {
        Task {
            do {
                if on {
                    guard await SpeechListener.authorize() else { return }
                    try await link.run([["t": "mic", "on": true]])
                    let link = self.link
                    try mic.start { pcm in Task { @MainActor in link.sendMicrophone(pcm) } }
                } else {
                    mic.stop()
                    try await link.run([["t": "mic", "on": false]])
                }
            } catch {
                mic.stop()
                message = error.localizedDescription == "no_virtual_cable"
                    ? String(localized: "To use the iPhone as the computer's microphone, install the free VB-CABLE driver on the computer, then restart WiFiTalk there.")
                    : error.localizedDescription
            }
        }
    }

    func stopAudio() {
        mic.stop(); speaker.stop(); listener.stop()
    }
}
