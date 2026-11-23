import Foundation

/// Launch arguments used by the UI tests (never set in normal use): recordings served by the mock computer,
/// used instead of the microphone for a dictation or a command.
enum TestHooks {
    static func url(_ name: String) -> URL? {
        guard let value = UserDefaults.standard.string(forKey: name), !value.isEmpty else { return nil }
        return URL(string: value)
    }
    static var commandRecording: URL? { url("uitestCommandAudio") }
    static var dictationRecording: URL? { url("uitestDictationAudio") }

    /// `-demoSnippets YES` (the demo video only): two saved texts behind the header's clipboard button.
    static func seedDemoSnippets() {
        guard UserDefaults.standard.bool(forKey: "demoSnippets") else { return }
        PasteSnippetStore.save([
            PasteSnippet(title: "Email signature", text: "Best regards,
IbnKabed"),
            PasteSnippet(title: "Home address", text: "221B Baker Street, London"),
        ])
    }
}
