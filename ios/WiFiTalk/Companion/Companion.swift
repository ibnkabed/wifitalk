import Foundation
import Network

struct AIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Resumes a continuation once, whichever callback comes first (all on the main actor).
@MainActor
final class Once {
    private var done = false
    func take() -> Bool { if done { return false }; done = true; return true }
}

/// `Companion` is the connection to the WiFiTalk companion on the computer: one TCP connection on the local Wi-Fi.
///
/// Each frame is [1 byte type][4 bytes big-endian length][payload]: 1 = JSON both ways, 2 = this phone's
/// microphone (PCM int16 mono 48 kHz), 3 = the computer's sound (PCM int16 stereo, rate announced in JSON).
/// The companion only executes; every decision is made here on the phone.
@MainActor
final class Companion: ObservableObject {
    enum State: Equatable { case idle, connecting, connected(name: String), failed(String) }

    static let port: UInt16 = 47821

    @Published private(set) var state: State = .idle
    @Published private(set) var virtualMicAvailable = false
    /// The computer said this phone's token is no longer paired (the user unpaired all phones there).
    private(set) var unpaired = false

    var onSpeakerFormat: ((Double) -> Void)?
    var onSpeakerAudio: ((Data) -> Void)?
    /// Pieces of a file the computer is sending (an action "get" in progress).
    var onFileChunk: ((Data) -> Void)?

    private var connection: NWConnection?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var helloReply: CheckedContinuation<[String: Any], Error>?

    var isConnected: Bool { if case .connected = state { return true }; return false }

    /// Connects and says hello with the saved token, or with the PIN shown on the computer for a first pairing.
    /// Returns the token to keep.
    func connect(address: String, pin: String?, token: String?) async throws -> String {
        disconnect()
        state = .connecting
        // "192.168.1.20" or "192.168.1.20:47821"
        var hostText = address.trimmingCharacters(in: .whitespaces)
        var port = Self.port
        if let colon = hostText.lastIndex(of: ":"), let p = UInt16(hostText[hostText.index(after: colon)...]) {
            port = p
            hostText = String(hostText[..<colon])
        }
        let host = NWEndpoint.Host(hostText)
        let conn = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: Self.parameters())
        connection = conn
        do {
            let once = Once()
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { [weak self] st in
                    Task { @MainActor in
                        switch st {
                        case .ready:
                            if once.take() { c.resume() }
                        case .failed(let e), .waiting(let e):
                            if once.take() { c.resume(throwing: e) } else { self?.lost(e.localizedDescription) }
                        case .cancelled:
                            if once.take() { c.resume(throwing: AIError(String(localized: "Connection closed"))) }
                        default: break
                        }
                    }
                }
                conn.start(queue: .main)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if once.take() {
                        conn.cancel()
                        c.resume(throwing: AIError(String(localized: "The computer did not answer. Is WiFiTalk running there, on the same Wi-Fi?")))
                    }
                }
            }
            receive(on: conn)
            var hello: [String: Any] = [:]
            if let token, !token.isEmpty { hello["token"] = token } else { hello["pin"] = pin ?? "" }
            let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
                helloReply = c
                sendJSON(["hello": hello])
            }
            if let error = reply["error"] as? String {
                unpaired = error == "unpaired"
                throw AIError(Self.describe(error))
            }
            unpaired = false
            guard let welcome = reply["welcome"] as? [String: Any], let newToken = welcome["token"] as? String else {
                throw AIError(String(localized: "Unexpected answer from the computer"))
            }
            virtualMicAvailable = welcome["mic"] as? Bool ?? false
            state = .connected(name: welcome["name"] as? String ?? "PC")
            return newToken
        } catch {
            connection?.cancel()
            connection = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        failAll(AIError(String(localized: "Disconnected")))
        state = .idle
    }

    /// Sends actions and waits for the computer's answer (and its clipboard text for "getclip").
    @discardableResult
    func run(_ actions: [[String: Any]]) async throws -> [String: Any] {
        guard isConnected else { throw AIError(String(localized: "Not connected to the computer")) }
        let id = nextID; nextID += 1
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            waiting[id] = c
            sendJSON(["id": id, "do": actions])
        }
        if reply["ok"] as? Bool == false {
            throw AIError(reply["error"] as? String ?? String(localized: "The computer could not do that"))
        }
        return reply
    }

    /// Fire and forget, for mouse moves and scrolls (many a second): the computer answers only on failure.
    func send(_ actions: [[String: Any]]) {
        guard isConnected else { return }
        let id = nextID; nextID += 1
        sendJSON(["id": id, "q": true, "do": actions])
    }

    func sendMicrophone(_ pcm: Data) {
        guard isConnected else { return }
        sendFrame(type: 2, pcm)
    }

    /// One piece of a file being sent to the computer; waits until it has left, so a large file is not
    /// held in memory all at once.
    func sendFileChunk(_ data: Data) async throws {
        guard isConnected, let connection else { throw AIError(String(localized: "Not connected to the computer")) }
        var frame = Data([4])
        var length = UInt32(data.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(data)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    // MARK: private

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func describe(_ code: String) -> String {
        switch code {
        case "wrong_pin": return String(localized: "Wrong PIN. Check the PIN in the WiFiTalk window on the computer.")
        case "locked": return String(localized: "Too many wrong PINs. Wait a minute and try again.")
        case "unpaired": return String(localized: "This iPhone was unpaired on the computer. Pair again with the PIN.")
        default: return code
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendFrame(type: 1, data)
    }

    private func sendFrame(type: UInt8, _ payload: Data) {
        var frame = Data([type])
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] head, _, done, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                guard let head, head.count == 5, error == nil else {
                    self.lost(error?.localizedDescription ?? String(localized: "Connection closed"))
                    return
                }
                let type = head[head.startIndex]
                let length = head.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                if length == 0 { self.handle(type: type, Data()); self.receive(on: conn); return }
                conn.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    Task { @MainActor in
                        guard self.connection === conn else { return }
                        guard let body, body.count == length, error == nil else {
                            self.lost(error?.localizedDescription ?? String(localized: "Connection closed"))
                            return
                        }
                        self.handle(type: type, body)
                        self.receive(on: conn)
                    }
                }
                _ = done
            }
        }
    }

    private func handle(type: UInt8, _ body: Data) {
        switch type {
        case 1:
            guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
            if let c = helloReply, msg["welcome"] != nil || msg["error"] != nil {
                helloReply = nil
                c.resume(returning: msg)
            } else if let speaker = msg["speaker"] as? [String: Any] {
                onSpeakerFormat?((speaker["rate"] as? NSNumber)?.doubleValue ?? 48000)
            } else if let id = (msg["done"] as? NSNumber)?.intValue, let c = waiting.removeValue(forKey: id) {
                c.resume(returning: msg)
            }
        case 3:
            onSpeakerAudio?(body)
        case 4:
            onFileChunk?(body)
        default:
            break
        }
    }

    private func lost(_ message: String) {
        guard connection != nil else { return }
        connection?.cancel()
        connection = nil
        failAll(AIError(message))
        state = .failed(message)
    }

    private func failAll(_ error: Error) {
        if let c = helloReply { helloReply = nil; c.resume(throwing: error) }
        let all = waiting; waiting = [:]
        for c in all.values { c.resume(throwing: error) }
    }
}
