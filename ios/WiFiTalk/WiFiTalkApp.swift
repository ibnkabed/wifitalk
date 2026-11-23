import SwiftUI

@main
struct WiFiTalkApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        FirebaseHybrid.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.link)
                .environmentObject(model.listener)
                .environmentObject(model.mic)
                .environmentObject(model.speaker)
                .environment(\.layoutDirection, Locale.current.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight)
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await model.reconnect() } }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Companion

    var body: some View {
        if model.isPaired {
            TabView {
                AssistantView().tabItem { Label("Assistant", systemImage: "sparkles") }
                TrackpadView().tabItem { Label("Trackpad", systemImage: "hand.point.up.left") }
                KeyboardView().tabItem { Label("Keyboard", systemImage: "keyboard") }
                ControlsView().tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { await model.reconnect() }
        } else {
            PairView()
        }
    }
}

/// The connection state, shown at the top of each tab; tapping it reconnects.
struct ConnectionBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Companion

    var body: some View {
        Button {
            Task { await model.reconnect() }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(text).font(.footnote).lineLimit(2)
                Spacer()
                if case .connecting = link.state { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var color: Color {
        switch link.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var text: String {
        switch link.state {
        case .connected(let name): return String(localized: "Connected to \(name)")
        case .connecting: return String(localized: "Connecting…")
        case .failed(let why): return String(localized: "Not connected: \(why) Tap to retry.")
        case .idle: return String(localized: "Not connected. Tap to connect.")
        }
    }
}

/// First run: the computer's address and the PIN shown by the WiFiTalk companion there.
struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""
    @State private var pin = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("Your iPhone becomes your computer's assistant, keyboard, trackpad, microphone and speaker.")
                            .font(.headline)
                        Text("1. On the Windows computer, run WiFiTalk.exe. Its icon appears beside the clock.\n2. Click the icon to see the address and PIN.\n3. Enter them here. Both devices must be on the same Wi-Fi.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Section("Computer") {
                    TextField("Address, like 192.168.1.20", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("PIN", text: $pin).keyboardType(.numberPad)
                }
                Section {
                    Button {
                        working = true
                        Task { await model.pair(address: address, pin: pin); working = false }
                    } label: {
                        HStack { Text("Pair"); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(address.isEmpty || pin.count != 6 || working)
                } footer: {
                    if let m = model.message { Text(m).foregroundStyle(.red) }
                }
            }
            .navigationTitle("WiFiTalk")
            .onAppear { if address.isEmpty { address = model.address } }
        }
    }
}
