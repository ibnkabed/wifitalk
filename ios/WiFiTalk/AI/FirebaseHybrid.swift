import Foundation
import NaturalLanguage
import FirebaseCore
import FirebaseAppCheck
import FirebaseAILogic
import FirebaseRemoteConfig
#if canImport(FoundationModels)
import FoundationModels
#endif
#if compiler(>=6.4) && canImport(FoundationModels) && canImport(GeminiLanguageModel)
import GeminiLanguageModel
#endif

/// The assistant's AI, with no key to paste: hybrid inference through Firebase AI Logic.
///
/// - A short text prompt in a language Apple's on-device model supports runs **on the device** with Apple's
///   Foundation Models framework (private, free, offline).
/// - Everything else (long or open-ended writing, Arabic, or a phone without Apple Intelligence) goes to
///   **Gemini in the cloud through Firebase AI Logic**. On iOS 27 the cloud Gemini model is reached through the
///   same Foundation Models `LanguageModelSession` API (`ai.geminiLanguageModel(name:)`), so one API serves both.
/// - If the on-device model fails, the same request falls back to the cloud.
///
/// Firebase is configured only when `GoogleService-Info.plist` is in the app bundle; it is added at build time
/// from a repository secret, never committed. App Check is enforced for AI Logic; the build's App Check debug
/// token (also a build secret) is handed to the debug provider. Remote Config holds the cloud model's name and
/// an on-device switch, so neither is fixed in the app.
@MainActor
final class FirebaseHybrid: ObservableObject {
    static let shared = FirebaseHybrid()

    /// Which engine answered the last request, shown under the answer.
    enum Engine: String { case onDevice, cloud }
    @Published private(set) var lastEngine: Engine?

    private(set) var isConfigured = false
    private var ai: FirebaseAI?

    static let defaultCloudModel = "gemini-3.5-flash-lite"
    /// Used when the main cloud model is busy (HTTP 429/500/503) or fails.
    static let defaultFallbackModel = "gemini-3.8-flash"
    /// Apple's on-device model takes 4096 tokens in and out; prompts above this many characters go to the cloud.
    static let onDeviceMaxChars = 6000

    /// Called once at launch, before any view asks for AI.
    func configure() {
        #if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)   // the demo-video workflow reads the traces as they happen
        #endif
        guard !isConfigured, Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        if let token = Bundle.main.object(forInfoDictionaryKey: "AppCheckDebugToken") as? String,
           !token.isEmpty, !token.hasPrefix("$(") {
            setenv("AppCheckDebugToken", token, 1)
        }
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        FirebaseApp.configure()
        ai = FirebaseAI.firebaseAI(backend: .googleAI())
        let rc = RemoteConfig.remoteConfig()
        rc.setDefaults(["cloud_model": Self.defaultCloudModel as NSObject,
                        "cloud_fallback_model": Self.defaultFallbackModel as NSObject,
                        "on_device": true as NSObject])
        rc.fetchAndActivate { _, _ in }
        isConfigured = true
    }

    private var cloudModelName: String {
        let name = RemoteConfig.remoteConfig().configValue(forKey: "cloud_model").stringValue
        return name.isEmpty ? Self.defaultCloudModel : name
    }

    private var cloudModels: [String] {
        let fallback = RemoteConfig.remoteConfig().configValue(forKey: "cloud_fallback_model").stringValue
        let second = fallback.isEmpty ? Self.defaultFallbackModel : fallback
        return second == cloudModelName ? [cloudModelName] : [cloudModelName, second]
    }

    private var onDeviceAllowed: Bool { RemoteConfig.remoteConfig().configValue(forKey: "on_device").boolValue }

    /// Whether this phone can run Apple's on-device model now (Apple Intelligence on and the model downloaded).
    var onDeviceReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// A text request: system instructions and the user's prompt. `json` asks the cloud model for JSON.
    /// The on-device try is cut off after `onDeviceTimeout` seconds, so a slow or stuck local model never blocks:
    /// the same request then goes to the cloud.
    func respond(system: String, prompt: String, json: Bool, temperature: Double) async throws -> String {
        guard let ai else { throw AIError(String(localized: "Firebase is not set up in this build")) }
        if onDeviceAllowed && fitsOnDevice(system + "\n" + prompt) {
            trace("on-device: trying (\(prompt.count) chars)")
            do {
                let text = try await Self.withTimeout(Self.onDeviceTimeout) {
                    try await self.onDevice(system: system, prompt: prompt, temperature: temperature)
                }
                if json && !Self.hasJSONObject(text) {
                    trace("on-device: reply is not JSON — falling back to the cloud")
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    trace("on-device: answered")
                    lastEngine = .onDevice
                    return text
                }
            } catch {
                trace("on-device: \(error) — falling back to the cloud")
            }
        }
        trace("cloud: \(cloudModelName), json=\(json)")
        let text = try await Self.withTimeout(Self.cloudTimeout) {
            try await self.cloud(ai, system: system, prompt: prompt, json: json, temperature: temperature)
        }
        trace("cloud: answered (\(text.count) chars)")
        lastEngine = .cloud
        return text
    }

    /// A request with one file (a PDF's pages or a figure): always the cloud, which reads files.
    func respond(file: Data, mime: String, prompt: String) async throws -> String {
        guard let ai else { throw AIError(String(localized: "Firebase is not set up in this build")) }
        trace("cloud file: \(mime), \(file.count) bytes")
        let text = try await Self.withTimeout(Self.cloudTimeout) {
            try await self.retrying { name in
                let reply = try await ai.generativeModel(modelName: name, requestOptions: RequestOptions(timeout: Self.requestTimeout))
                    .generateContent(InlineDataPart(data: file, mimeType: mime), prompt)
                return reply.text ?? ""
            }
        }
        lastEngine = .cloud
        return text
    }

    // MARK: private

    static let onDeviceTimeout: Double = 30
    static let cloudTimeout: Double = 150
    static let requestTimeout: Double = 45

    /// True when the text holds a JSON object (the callers read the outermost {...}).
    private static func hasJSONObject(_ text: String) -> Bool {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let data = String(text[a...b]).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Debug builds print each routing step (the demo-video workflow saves the app's output).
    private func trace(_ line: String) {
        #if DEBUG
        print("[FirebaseHybrid] " + line)
        #endif
    }

    private struct Timeout: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "no reply in \(Int(seconds)) s" }
    }

    /// Runs `op`, or throws `Timeout` when it takes longer than `seconds`.
    private static func withTimeout<T: Sendable>(_ seconds: Double,
                                                 _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout(seconds: seconds) }
            return first
        }
    }

    /// Short enough for the on-device context, and in a language the on-device model supports.
    private func fitsOnDevice(_ text: String) -> Bool {
        guard onDeviceReady, text.count <= Self.onDeviceMaxChars else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let code = recognizer.dominantLanguage?.rawValue ?? "en"
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: code))
        }
        #endif
        return false
    }

    private func onDevice(system: String, prompt: String, temperature: Double) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
            let reply = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return reply.content
        }
        #endif
        throw AIError("on-device model unavailable")
    }

    private func cloud(_ ai: FirebaseAI, system: String, prompt: String, json: Bool,
                       temperature: Double) async throws -> String {
        #if compiler(>=6.4) && canImport(FoundationModels) && canImport(GeminiLanguageModel)
        // iOS 27: Gemini through the same Foundation Models session API as the on-device model.
        if #available(iOS 27.0, *), !json {
            let session = LanguageModelSession(model: ai.geminiLanguageModel(name: cloudModelName), instructions: system)
            do {
                let reply = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
                if !reply.content.isEmpty { return reply.content }
            } catch {
                trace("cloud (LanguageModelSession): \(error) — trying generateContent")
            }
        }
        #endif
        return try await retrying { name in
            let model = ai.generativeModel(
                modelName: name,
                // Gemini 3.x and later set their own temperature; only the JSON reply is asked for
                generationConfig: json ? GenerationConfig(responseMIMEType: "application/json") : nil,
                systemInstruction: ModelContent(role: "system", parts: system),
                requestOptions: RequestOptions(timeout: Self.requestTimeout)
            )
            return try await model.generateContent(prompt).text ?? ""
        }
    }

    /// Calls `op` with the main cloud model, then the fallback model, each tried twice with a short pause, so a
    /// busy model (HTTP 429/500/503 "high demand") does not fail the request.
    private func retrying(_ op: (String) async throws -> String) async throws -> String {
        var last: Error?
        for name in cloudModels {
            for attempt in 0..<2 {
                do {
                    let text = try await op(name)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        trace("cloud: \(name) answered")
                        return text
                    }
                } catch {
                    last = error
                    trace("cloud: \(name) attempt \(attempt + 1): \(error)")
                    // a used-up quota will not come back in two seconds: go to the next model
                    let text = "\(error)".lowercased()
                    if text.contains("quota") || text.contains("429") || text.contains("resource_exhausted") { break }
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw AIError("Gemini (Firebase): " + (last?.localizedDescription ?? String(localized: "unexpected reply")))
    }
}
