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
}
