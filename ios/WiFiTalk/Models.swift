import Foundation

struct PairResponse: Decodable {
    let token: String
    let name: String
}

struct TalkResult: Decodable {
    let rawText: String
    let correctedText: String
    let correctionWarning: String?
    let language: String?
    let rawScript: String?
    /// Which service actually transcribed, and which proofread it. Both are
    /// optional so an older companion still decodes.
    let provider: String?
    let correctionProvider: String?

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case correctedText = "corrected_text"
        case correctionWarning = "correction_warning"
        case language
        case rawScript = "raw_script"
        case provider
        case correctionProvider = "correction_provider"
    }
}

/// The speech service the phone sends this recording to.
///
/// The rotation is manual on purpose. Each service has its own free daily
/// allowance, so when one starts refusing the user moves the next dictation
/// somewhere else - and always knows which model wrote the text that just
/// landed in the Windows field.
///
/// This is a value carried from the companion, not a list written here. It
/// used to be an enum of three cases, which meant that adding a service on
/// Windows was not finished until a new build reached the iPhone - and a
/// build reaching this iPhone means Sideloadly and a cable, by hand, every
/// time. `/health` already reports every provider with its label and its
/// readiness, so the phone reads that list instead of keeping its own copy.
struct TranscriptionProvider: Identifiable, Hashable, Sendable {
    let id: String
    let shortLabel: String
    let fullLabel: String

    /// The value sent to the companion as `?provider=`.
    var requestCode: String { id }

    /// What the list looks like before `/health` has answered, and what fills
    /// the gaps for a companion too old to send a short name. The companion's
    /// own values replace these the moment it answers, so this going stale
    /// costs a label on a first launch and nothing else.
    static let seed: [TranscriptionProvider] = [
        // Apple's speech recognizer on the phone, then a light proofreading by the hybrid AI (on-device Apple
        // model first, Gemini through Firebase AI Logic otherwise); or the words exactly as Apple heard them.
        .init(id: "ai", shortLabel: "AI", fullLabel: "Apple + AI (Firebase)"),
        .init(id: "raw", shortLabel: "Apple", fullLabel: "Apple"),
    ]

    static let fallback = seed[0]

    /// Both are always ready: neither needs a key on the computer.
    static var statuses: [ProviderStatus] {
        seed.map { ProviderStatus(id: $0.id, label: $0.fullLabel, short: $0.shortLabel, model: $0.id == "ai" ? "Firebase AI Logic" : "Speech",
                                  ready: true, canCorrect: $0.id == "ai") }
    }
    /// A provider the companion named that this build has never heard of. It
    /// is still selectable and still sent: the companion is the authority on
    /// what it can do, and a name this build lacks a label for is no reason
    /// to hide a service that works.
    static func unnamed(_ id: String) -> TranscriptionProvider {
        let trimmed = id.isEmpty ? "?" : id
        return .init(id: trimmed, shortLabel: String(trimmed.prefix(4)), fullLabel: trimmed)
    }
}

/// One provider as the companion reports it from `/health`.
struct ProviderStatus: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    /// Absent from a companion that predates the small key on the phone.
    let short: String?
    let model: String
    let ready: Bool
    let canCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, short, model, ready
        case canCorrect = "can_correct"
    }

    var provider: TranscriptionProvider {
        let known = TranscriptionProvider.seed.first { $0.id == id }
        return TranscriptionProvider(
            id: id,
            shortLabel: short ?? known?.shortLabel ?? String(id.prefix(4)),
            fullLabel: label.isEmpty ? (known?.fullLabel ?? id) : label
        )
    }
}

/// Language hint sent to the speech model. `automatic` lets Whisper detect the
/// language; the explicit cases stop it from answering with a translation.
enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case arabic
    case english

    var id: String { rawValue }

    /// The value sent to the companion, or `nil` for automatic detection.
    var requestCode: String? {
        switch self {
        case .automatic: return nil
        case .arabic: return "ar"
        case .english: return "en"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic: return "Auto"
        case .arabic: return "AR"
        case .english: return "EN"
        }
    }
}

struct MicStartResult: Decodable {
    let ok: Bool
    let device: String
    let channels: Int
    let sampleRate: Int
    let voiceProcessing: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, device, channels
        case sampleRate = "sample_rate"
        case voiceProcessing = "voice_processing"
    }
}

struct ClipboardResponse: Decodable {
    let text: String
}

struct HealthResponse: Decodable {
    let ok: Bool
    let name: String
    let apiKeyReady: Bool
    /// Absent when the companion predates manual provider selection.
    let providers: [ProviderStatus]?
    let defaultProvider: String?
    /// The one model that proofreads every transcript through the guardian's
    /// gateway. Absent from a companion older than 2026-10-05.
    let corrector: String?

    enum CodingKeys: String, CodingKey {
        case ok, name, providers, corrector
        case apiKeyReady = "api_key_ready"
        case defaultProvider = "default_provider"
    }
}

struct SpeakerStartResult: Decodable {
    let ok: Bool
    let session: String
    let device: String
    let sampleRate: Int
    let channels: Int

    enum CodingKeys: String, CodingKey {
        case ok, session, device, channels
        case sampleRate = "sample_rate"
    }
}

/// One folder inside the computer's transfer folder, as the phone sees it.
///
/// The phone never names an absolute path: `path` is relative to the shared
/// folder, which is the only thing the companion will resolve.
struct RemoteFileListing: Decodable {
    let root: String
    let path: String
    let parent: String?
    let entries: [RemoteFile]
}

struct RemoteFile: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int
    let modified: Double

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified
        case isDirectory = "is_dir"
    }

    var sizeLabel: String {
        if isDirectory { return "Folder" }
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(size)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(size) \(units[0])"
            : String(format: "%.1f %@", value, units[index])
    }

    var modifiedLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: modified))
    }

    /// SF Symbol picked from the extension, so a folder of photos reads as
    /// photos at a glance rather than as twenty identical rows.
    var icon: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "doc.zipper"
        case "doc", "docx", "txt", "md", "rtf": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        default: return "doc"
        }
    }
}

/// What the computer did with one spoken command.
///
/// `reply` is written by the companion, in Arabic, for this line of the
/// screen; `files` are the ones the command put in the transfer folder for the
/// phone to fetch (a file sent from Explorer, or a screenshot asked for here).
struct CommandResult: Decodable {
    let ok: Bool
    let heard: String
    let reply: String
    let files: [CommandFile]
    let provider: String?
    /// Set only for "افتح القفل": the phone sends its stored PIN next.
    let unlock: Bool?
    /// A new command waiting for the owner's yes (owner, 2026-11-07).
    let pending: PendingCommand?
}

/// What the model understood. Nothing runs until the owner answers.
struct PendingCommand: Decodable, Identifiable {
    let id: String
    let text: String
    let seconds: Int?
}

struct CommandFile: Decodable, Hashable {
    let name: String
    let path: String
    let size: Int

    /// The same shape the files sheet downloads, so one download path serves both.
    var remote: RemoteFile {
        RemoteFile(name: name, path: path, isDirectory: false, size: size, modified: 0)
    }
}

struct UploadedFile: Decodable {
    let ok: Bool
    let name: String
    let path: String
    let size: Int
}

struct EmptyResponse: Decodable {
    let ok: Bool
}

enum RemoteInputCommand: Sendable {
    case edit(backspaces: Int, inserted: String)
    case text(String)
    case key(String, modifiers: [String], count: Int)
    case combo(String, modifiers: [String])
}

/// One thing the finger did on the trackpad, in the wire shape the companion's
/// `/v1/mouse` route reads.
///
/// A batch is sent rather than a request per event: a tap is a press and a
/// release, a drag is a move with a button already held, and the order inside
/// one packet is what keeps them from arriving inside out.
enum MouseEvent: Sendable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    case click(button: String, count: Int)
    case button(String, down: Bool)

    var payload: [String: Any] {
        switch self {
        case .move(let dx, let dy):
            return ["t": "move", "dx": dx, "dy": dy]
        case .scroll(let dx, let dy):
            return ["t": "scroll", "dx": dx, "dy": dy]
        case .click(let button, let count):
            return ["t": "click", "b": button, "n": count]
        case .button(let button, let down):
            return ["t": down ? "down" : "up", "b": button]
        }
    }
}

struct APIError: Decodable {
    let error: String
}

enum WiFiTalkError: LocalizedError {
    case invalidAddress
    case notPaired
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "The computer address isn't valid"
        case .notPaired: return "Pair with the computer first"
        case .server(let message): return message
        case .invalidResponse: return "The computer sent an unexpected answer"
        }
    }
}
