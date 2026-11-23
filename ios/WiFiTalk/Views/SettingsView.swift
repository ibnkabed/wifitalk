import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Companion
    @ObservedObject private var hybrid = FirebaseHybrid.shared
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    LabeledContent("Address", value: model.address)
                    Button("Reconnect") { Task { link.disconnect(); await model.reconnect() } }
                    Button("Forget this computer", role: .destructive) { confirmForget = true }
                }

                Section {
                    Picker("I speak", selection: $model.speechLanguage) {
                        Text("Phone language").tag("auto")
                        Text("English").tag("en")
                        Text("العربية").tag("ar")
                    }
                } header: {
                    Text("Voice")
                }

                Section {
                    Label(hybrid.isConfigured ? String(localized: "Ready with no key: Gemini through Firebase AI Logic")
                                              : String(localized: "Not available in this build"),
                          systemImage: hybrid.isConfigured ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundColor(hybrid.isConfigured ? .green : .secondary)
                    LabeledContent("Apple's model on this iPhone",
                                   value: hybrid.onDeviceReady ? String(localized: "Available") : String(localized: "Not available here"))
                } header: {
                    Text("Built-in AI")
                } footer: {
                    Text("A short request in a language Apple's on-device model supports, such as English, is understood on this iPhone: private, free and offline. Longer writing, Arabic, and phones without Apple Intelligence use Gemini in the cloud through Firebase AI Logic. The computer only carries out the actions; it runs no AI.")
                }

                Section("About") {
                    Text("WiFiTalk turns your iPhone into your computer's assistant, keyboard, trackpad, microphone and speaker over your Wi-Fi.")
                        .font(.callout)
                    SwiftUI.Link(destination: URL(string: "https://github.com/ibnkabed/wifitalk")!) {
                        Label("Source code and the Windows companion", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Text("Copyright (c) 2026 IbnKabed")
                        .font(.caption).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Forget this computer?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forget() }
            }
        }
    }
}
