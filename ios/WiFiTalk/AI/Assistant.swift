import Foundation

/// Turns what the user says ("open Chrome and search for flights to Riyadh") into the plain actions the computer
/// companion executes. All understanding happens here, on the phone, through `FirebaseHybrid`: Apple's on-device
/// model for a short request in a language it supports, else Gemini in the cloud through Firebase AI Logic.
enum Assistant {
    struct Plan {
        var say: String
        var actions: [[String: Any]]
        /// Shutting down, restarting or sleeping the computer is confirmed on the phone first.
        var needsConfirmation: Bool { actions.contains { ($0["t"] as? String) == "power" && ($0["s"] as? String) != "lock" } }
    }

    static let system = """
    You control a Windows computer for the user. Turn the request into actions and reply with ONLY one JSON object:
    {"say": "<a short reply in the user's language>", "actions": [ ... ]}
    Actions:
    {"t":"open","s":"<a program name such as chrome, notepad, word, excel, spotify, calculator; or a full URL; or ms-settings:...>"}
    {"t":"text","s":"<text to type where the cursor is>"}
    {"t":"keys","k":"<keys joined by +, such as ctrl+t, ctrl+s, alt+tab, alt+f4, win+d, enter, tab, esc, volumeup, volumedown, mute, playpause, next, previous>"}
    {"t":"wait","ms":<milliseconds, at most 3000>}
    {"t":"power","s":"lock|sleep|shutdown|restart"}
    Rules:
    - Use as few actions as possible. After opening a program, wait 1500 ms before typing into it.
    - To search the web, open "https://www.google.com/search?q=" followed by the words joined by +.
    - To open a website, open its full https URL.
    - When the user asks you to write something (an email, a reply, a paragraph), write it yourself, in full and
      in the language the user asks for, and type it with one text action.
    - If the request is unclear or impossible, return "actions": [] and ask or explain in "say".
    Example: "open notepad and write hello" ->
    {"say":"Opening Notepad.","actions":[{"t":"open","s":"notepad"},{"t":"wait","ms":1500},{"t":"text","s":"hello"}]}
    Example: "turn the volume up" ->
    {"say":"Volume up.","actions":[{"t":"keys","k":"volumeup"},{"t":"keys","k":"volumeup"},{"t":"keys","k":"volumeup"}]}
    """

    static func plan(for request: String) async throws -> Plan {
        let reply = try await FirebaseHybrid.shared.respond(system: system, prompt: request, json: true, temperature: 0.2)
        return try parse(reply)
    }

    /// Reads the model's JSON and keeps only the actions the companion knows, within safe limits.
    static func parse(_ reply: String) throws -> Plan {
        guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError(String(localized: "The assistant's answer could not be read. Try saying it differently."))
        }
        let say = object["say"] as? String ?? ""
        var actions: [[String: Any]] = []
        for case let item as [String: Any] in (object["actions"] as? [Any] ?? []).prefix(20) {
            guard let t = item["t"] as? String else { continue }
            switch t {
            case "open":
                if let s = item["s"] as? String, !s.isEmpty { actions.append(["t": "open", "s": s]) }
            case "text":
                if let s = item["s"] as? String, !s.isEmpty { actions.append(["t": "text", "s": String(s.prefix(8000))]) }
            case "keys":
                if let k = item["k"] as? String, !k.isEmpty { actions.append(["t": "keys", "k": k.lowercased()]) }
            case "wait":
                let ms = (item["ms"] as? NSNumber)?.intValue ?? 1000
                actions.append(["t": "wait", "ms": min(max(ms, 0), 3000)])
            case "power":
                if let s = item["s"] as? String, ["lock", "sleep", "shutdown", "restart"].contains(s) {
                    actions.append(["t": "power", "s": s])
                }
            default:
                continue
            }
        }
        return Plan(say: say, actions: actions)
    }

    /// One line per action, for the plan shown on the phone before and while it runs.
    static func describe(_ action: [String: Any]) -> String {
        let t = action["t"] as? String ?? ""
        switch t {
        case "open": return String(localized: "Open \(action["s"] as? String ?? "")")
        case "text":
            let s = action["s"] as? String ?? ""
            return String(localized: "Type “\(s.count > 60 ? String(s.prefix(60)) + "…" : s)”")
        case "keys": return String(localized: "Press \(action["k"] as? String ?? "")")
        case "wait":
            let seconds = String(format: "%.1f", Double((action["ms"] as? Int) ?? 0) / 1000)
            return String(localized: "Wait \(seconds) s")
        case "power": return String(localized: "Power: \(action["s"] as? String ?? "")")
        default: return t
        }
    }
}
