import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    /// UI tests only (launch argument): a recording to hand back instead of the microphone's, because a CI
    /// simulator has no microphone. Set by the app model for each dictation or command.
    var testRecording: URL?

    private func requirePermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw WiFiTalkError.server("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone › WiFiTalk")
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            if !granted {
                throw WiFiTalkError.server("WiFiTalk wasn't allowed to use the microphone")
            }
        @unknown default:
            throw WiFiTalkError.server("Couldn't check microphone access")
        }
    }

    /// - Parameter sharedWithStream: `true` when the computer microphone or the
    ///   computer speaker already owns the audio session. `.record` would
    ///   silence a running speaker stream outright, so the shared case takes
    ///   `.playAndRecord` instead - the same compromise the two streamers
    ///   already make when they run together.
    func start(sharedWithStream: Bool = false) async throws {
        if testRecording != nil {
            isRecording = true
            return
        }
        try await requirePermission()
        recorder?.stop()
        recorder = nil
        fileURL = nil
        let session = AVAudioSession.sharedInstance()
        if sharedWithStream {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker]
            )
        } else {
            try session.setCategory(.record, mode: .measurement)
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wifitalk-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let value = try AVAudioRecorder(url: url, settings: settings)
        value.delegate = self
        value.isMeteringEnabled = true
        guard value.prepareToRecord() else {
            // Same rule as on the way out: a stream that owns this session must
            // survive a dictation that could not even start.
            if !sharedWithStream {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw WiFiTalkError.server("Couldn't prepare the recording")
        }
        guard value.record() else { throw WiFiTalkError.server("Couldn't start recording") }
        recorder = value
        fileURL = url
        isRecording = true
    }

    /// - Parameter keepSessionActive: `true` while the computer microphone or
    ///   the computer speaker is still streaming. Deactivating the session
    ///   under a live stream kills it, which is why the two streamers already
    ///   hand this flag to each other.
    func stop(keepSessionActive: Bool = false) async -> URL? {
        if let test = testRecording {
            isRecording = false
            testRecording = nil
            guard let (data, _) = try? await URLSession.shared.data(from: test) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wifitalk-test-\(UUID().uuidString).wav")
            try? data.write(to: url)
            return url
        }
        guard let activeRecorder = recorder else { return nil }
        let duration = activeRecorder.currentTime
        activeRecorder.stop()
        recorder = nil
        isRecording = false
        if !keepSessionActive {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              duration >= 0.15,
              size > 44 else {
            return nil
        }
        return fileURL
    }
}
