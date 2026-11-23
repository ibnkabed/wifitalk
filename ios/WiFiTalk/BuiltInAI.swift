import SwiftUI

/// The built-in AI in the settings: ready with no key, and whether Apple's on-device model can answer on this phone.
struct BuiltInAISection: View {
    @ObservedObject private var hybrid = FirebaseHybrid.shared

    var body: some View {
        Section {
            Label(hybrid.isConfigured ? L("Ready with no key: Gemini through Firebase AI Logic") : L("Not available in this build"),
                  systemImage: hybrid.isConfigured ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundColor(hybrid.isConfigured ? .green : .secondary)
            LabeledContent("Apple's model on this iPhone", value: hybrid.onDeviceReady ? L("Available") : L("Not available here"))
            if let engine = hybrid.lastEngine {
                LabeledContent("Last request", value: engine == .onDevice ? L("On this iPhone") : L("In the cloud"))
            }
        } header: {
            Text("Built-in AI")
        } footer: {
            Text("The Command button understands what you say and turns it into actions the computer carries out; the “AI” key next to Dictate proofreads what you dictated before it is typed. A short request in a language Apple's on-device model supports, such as English, is understood on this iPhone: private, free and offline. Anything else, such as other languages or long writing, is understood by Gemini in the cloud through Firebase AI Logic. The computer only carries out actions; it runs no AI.")
        }
    }
}

/// What the app is, its source, and the copyright line.
struct AboutSection: View {
    var body: some View {
        Section("About") {
            Text("WiFiTalk turns your iPhone into your Windows computer's AI assistant, keyboard, trackpad, microphone and speaker, over your Wi-Fi.")
                .font(.callout)
            Link(destination: URL(string: "https://github.com/ibnkabed/wifitalk")!) {
                Label("Source code and the Windows companion", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Text("Copyright (c) 2026 IbnKabed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
