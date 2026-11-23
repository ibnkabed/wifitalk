import SwiftUI

/// Sound, media and power, plus the computer's sound on the iPhone and the iPhone as the computer's microphone.
struct ControlsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Companion
    @EnvironmentObject var mic: MicSender
    @EnvironmentObject var speaker: SpeakerPlayer
    @State private var confirm: String?

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBar().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

                Section {
                    Toggle(isOn: Binding(get: { speaker.running }, set: { model.setSpeaker($0) })) {
                        Label("Hear the computer on this iPhone", systemImage: "speaker.wave.2.fill")
                    }
                    Toggle(isOn: Binding(get: { mic.running }, set: { model.setMic($0) })) {
                        Label("Use this iPhone as the computer's microphone", systemImage: "mic.fill")
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text(link.virtualMicAvailable
                         ? "The computer sees your voice on the “CABLE Output” microphone."
                         : "The microphone needs the free VB-CABLE driver on the computer.")
                }

                Section("Volume and media") {
                    grid([("speaker.minus.fill", "volumedown"), ("speaker.slash.fill", "mute"), ("speaker.plus.fill", "volumeup")])
                    grid([("backward.fill", "previous"), ("playpause.fill", "playpause"), ("forward.fill", "next")])
                }

                Section("Power") {
                    Button { model.power("lock") } label: { Label("Lock", systemImage: "lock.fill") }
                    Button { confirm = "sleep" } label: { Label("Sleep", systemImage: "moon.fill") }
                    Button(role: .destructive) { confirm = "restart" } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { confirm = "shutdown" } label: { Label("Shut down", systemImage: "power") }
                }
            }
            .navigationTitle("Controls")
            .alert("Are you sure?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Yes", role: .destructive) { if let c = confirm { model.power(c) }; confirm = nil }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text(confirm.map { String(localized: "The computer will \($0) now.") } ?? "")
            }
            .overlay(alignment: .bottom) {
                if let m = model.message {
                    Text(m).font(.footnote).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
                        .onTapGesture { model.message = nil }
                }
            }
        }
    }

    private func grid(_ keys: [(String, String)]) -> some View {
        HStack {
            ForEach(keys, id: \.1) { key in
                Button { model.keys(key.1) } label: {
                    Image(systemName: key.0).font(.title2).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
