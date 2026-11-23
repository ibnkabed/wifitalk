import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isPaired {
                KeyboardHomeView()
            } else {
                PairView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PairView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedField: PairField?

    private enum PairField: Hashable {
        case address
        case pin
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 82))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.cyan, .blue.opacity(0.35))
                Text("WiFiTalk").font(.largeTitle.bold())
                Text("Your computer's assistant, keyboard and sound in one app")
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    TextField(
                        "Computer address, e.g. 192.168.1.20",
                        text: Binding(
                            get: { model.address },
                            set: { model.address = normalizeAddressInput($0) }
                        )
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.URL)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .address)
                        .onSubmit { focusedField = .pin }
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                    TextField(
                        "Pairing PIN — 6 digits",
                        text: Binding(
                            get: { model.pin },
                            set: { model.pin = normalizePairingPIN($0) }
                        )
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapableNumberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .pin)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                    Button {
                        Task { await model.pair() }
                    } label: {
                        Label("Connect", systemImage: "link").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.address.isEmpty || model.pin.count != 6 || model.isBusy)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                if !model.message.isEmpty {
                    Text(model.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
    }
}

private func westernizedDigits(_ value: String) -> String {
    value.unicodeScalars.reduce(into: "") { result, scalar in
        switch scalar.value {
        case 0x0660...0x0669:
            result.append(String(scalar.value - 0x0660))
        case 0x06F0...0x06F9:
            result.append(String(scalar.value - 0x06F0))
        default:
            result.append(contentsOf: String(scalar))
        }
    }
}

private func normalizeAddressInput(_ value: String) -> String {
    String(westernizedDigits(value).filter { !$0.isWhitespace })
}

private func normalizePairingPIN(_ value: String) -> String {
    let digits = westernizedDigits(value).filter { character in
        guard let ascii = character.asciiValue else { return false }
        return (48...57).contains(ascii)
    }
    return String(digits.prefix(6))
}

private func normalizeLoginInputPIN(_ value: String) -> String {
    let digits = westernizedDigits(value).filter { character in
        guard let ascii = character.asciiValue else { return false }
        return (48...57).contains(ascii)
    }
    return String(digits.prefix(8))
}

private struct KeyboardHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var modifiers: Set<String> = []
    @State private var showRestartConfirmation = false
    @State private var showShutdownConfirmation = false
    @State private var showSettings = false
    @State private var showFiles = false
    @State private var showSnippets = false
    @State private var isKeyboardVisible = false
    @State private var showTypedCommand = false
    @State private var typedCommand = ""

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 560
            // Top-aligned so that on a short screen, with the keyboard taking
            // most of it, what falls off the bottom is the modifier row rather
            // than half the header and half the text box.
            ZStack(alignment: .top) {
                // The background is a view of its own rather than a modifier so
                // it can carry the gesture that puts the keyboard away. Until
                // now nothing on this screen could resign the text view, and the
                // only way back was to quit the app.
                Color(red: 0.027, green: 0.043, blue: 0.071)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                VStack(spacing: compact ? 5 : 8) {
                    header
                    editor(height: compact ? 76 : 126)
                    actionRow(compact: compact)
                    statusLine
                    arrows(compact: compact)
                    trackpad
                    voiceRow(compact: compact)
                    modifierRow(compact: compact)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in
            isKeyboardVisible = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            isKeyboardVisible = false
        }
        .task {
            while !Task.isCancelled {
                await model.checkConnection()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showFiles) { FilesView() }
        .sheet(isPresented: Binding(
            get: { !model.commandDownloads.isEmpty },
            set: { if !$0 { model.commandDownloads = [] } }
        )) {
            ShareSheet(urls: model.commandDownloads)
        }
        .alert("Do this on the computer?", isPresented: Binding(
            get: { model.pendingCommand != nil },
            set: { if !$0 { model.pendingCommand = nil } }
        )) {
            Button("Do it") { Task { await model.answerPendingCommand(approve: true) } }
            Button("No", role: .cancel) { Task { await model.answerPendingCommand(approve: false) } }
        } message: {
            Text(model.pendingCommand?.text ?? "")
        }
        .alert("Type a command for the computer", isPresented: $showTypedCommand) {
            TextField("e.g. Open Chrome and search for the weather in Riyadh", text: $typedCommand)
            Button("Do it") {
                let text = typedCommand
                typedCommand = ""
                Task { await model.runTypedCommand(text) }
            }
            Button("Cancel", role: .cancel) { typedCommand = "" }
        } message: {
            Text("The AI on your iPhone understands it, then the computer carries it out.")
        }
        .alert("Restart the computer?", isPresented: $showRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) { Task { await model.power("restart") } }
        } message: {
            Text("The Windows computer will restart now.")
        }
        .alert("Shut down the computer?", isPresented: $showShutdownConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Shut down", role: .destructive) { Task { await model.power("shutdown") } }
        } message: {
            Text("The Windows computer will shut down now.")
        }
    }

    /// The app's own mark and name, and the row of small controls.
    ///
    /// The connection badge sits at the head of that row - to the right of the
    /// restart button in this right-to-left layout - because the middle of the
    /// action row below it is now the way into the files, and a state light
    /// does not need a button's worth of screen to be read.
    private var header: some View {
        HStack(spacing: 8) {
            Image("AppMark")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("WiFiTalk")
                .font(.subheadline.bold())
                .lineLimit(1)
                .environment(\.layoutDirection, .leftToRight)
            Spacer(minLength: 4)
            HeaderButton(
                icon: model.isConnected ? "wifi" : "wifi.slash",
                tint: model.isConnected ? .green : .red
            ) {
                Task { await model.reportConnection() }
            }
            .accessibilityLabel("Connection: \(model.connectionLabel)")
            .accessibilityIdentifier("connection")
            // saved texts typed into the computer without any model.
            HeaderButton(icon: "list.clipboard.fill", tint: .cyan) {
                if filledSnippets.isEmpty {
                    showSettings = true
                } else {
                    showSnippets.toggle()
                }
            }
            .accessibilityLabel("Paste snippets")
            .popover(isPresented: $showSnippets, arrowEdge: .top) {
                snippetList.presentationCompactAdaptation(.popover)
            }
            HeaderButton(icon: "arrow.clockwise", tint: .orange) { showRestartConfirmation = true }
                .accessibilityIdentifier("restart")
            HeaderButton(icon: "power", tint: .red) { showShutdownConfirmation = true }
                .accessibilityIdentifier("shutdown")
            HeaderButton(icon: "gearshape") { showSettings = true }
                .accessibilityIdentifier("settings")
        }
    }

    private var filledSnippets: [PasteSnippet] {
        model.pasteSnippets.filter(\.isFilled)
    }

    /// A narrow column, each title centred so right-to-left and left-to-right
    /// titles sit alike; a longer title is
    /// cut with an ellipsis, and the text it pastes stays whole.
    private var snippetList: some View {
        VStack(spacing: 0) {
            ForEach(Array(filledSnippets.enumerated()), id: \.element.id) { index, snippet in
                if index > 0 { Divider() }
                Button {
                    showSnippets = false
                    model.pasteSnippet(snippet)
                } label: {
                    Text(snippet.title)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 132)
    }

    private func editor(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.04, green: 0.067, blue: 0.11))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.09)))
            LiveTextEditor(
                text: $draft,
                onEdit: handleEdit,
                onEmptyBackspace: { model.sendKey("backspace", modifiers: activeModifiers()) }
            )
            HStack {
                Spacer()

                Button {
                    draft = ""
                } label: {
                    Image(systemName: "eraser")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Clear this box only")
                .accessibilityIdentifier("clear")
            }
            .padding(7)
        }
        .frame(height: height)
    }

    /// The clipboard pair, with the way into the files between them.
    ///
    /// The circle used to be the connection light; that moved up to the header
    /// and left the best-placed target on the screen holding nothing. Files
    /// take it: the two buttons beside it already move text between the two
    /// machines, and this moves everything else.
    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 11) {
            ActionButton(title: "Copy to computer", icon: "doc.on.clipboard") {
                Task { await model.copyPhoneClipboardToPC() }
            }
            .accessibilityIdentifier("copyToPC")
            Button {
                showFiles = true
            } label: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: compact ? 42 : 48, height: compact ? 42 : 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.cyan.opacity(0.75), in: Circle())
            .overlay(Circle().stroke(Color.cyan, lineWidth: 1.5))
            .accessibilityLabel("Transfer files")
            .accessibilityIdentifier("files")

            ActionButton(title: "Get from computer", icon: "clipboard") {
                Task { await model.copyPCClipboardToPhone() }
            }
            .accessibilityIdentifier("getFromPC")
        }
    }

    /// Dictation and its two options, sitting directly above the modifier row.
    /// In this right-to-left layout the last child is the leftmost one, so the
    /// voice button lands above Esc with its options to its right.
    private func voiceRow(compact: Bool) -> some View {
        let height: CGFloat = compact ? 37 : 43
        return HStack(spacing: 5) {
            OptionKey(
                title: model.transcriptionProvider.shortLabel,
                tint: providerKeyTint,
                height: height
            ) { model.cycleTranscriptionProvider() }
                .accessibilityIdentifier("dictationMode")
                .accessibilityLabel("Dictation: \(model.transcriptionProvider.fullLabel)")
            OptionKey(
                title: model.dictationLanguage.shortLabel,
                tint: model.dictationLanguage == .automatic ? .cyan : .orange,
                height: height
            ) { model.cycleDictationLanguage() }
                .accessibilityIdentifier("dictationLanguage")
                .accessibilityLabel("Dictation language: \(model.dictationLanguage.shortLabel)")
            commandButton(height: height)
            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(
                    model.isRecording ? "Stop and send" : "Dictate",
                    systemImage: model.isRecording ? "stop.fill" : "waveform.badge.mic"
                )
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: height)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                model.isRecording ? Color.red : Color.cyan.opacity(0.85),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(model.isRecording ? Color.red : Color.cyan, lineWidth: 1)
            )
            .disabled(model.isRecordingCommand || model.isRunningCommand)
            .accessibilityIdentifier("dictate")
        }
    }

    /// The command button: tap, say what the computer should do, tap again.
    ///
    /// Beside dictation because it is dictation's twin - the same recorder and
    /// the same service key to its right - with the opposite result: nothing
    /// heard is typed, the computer acts on it instead. Orange while it
    /// listens, so the two can never be mistaken for each other mid-sentence.
    private func commandButton(height: CGFloat) -> some View {
        let listening = model.isRecordingCommand
        let working = model.isRunningCommand
        return Button {
            Task { await model.toggleCommand() }
        } label: {
            VStack(spacing: 1) {
                if working {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: listening ? "stop.fill" : "command")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(listening ? "Run" : "Command")
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .frame(width: 58, height: height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            listening ? Color.orange : Color.purple.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(listening ? Color.orange : Color.purple, lineWidth: 1)
        )
        .disabled(model.isRecording || working)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if !listening && !working { showTypedCommand = true }
        })
        .accessibilityLabel(listening ? "Run the command" : "Voice command for the computer")
        .accessibilityIdentifier("command")
    }

    /// Red means the companion says this provider has no credentials, so the
    /// next dictation would fail before it left the phone.
    ///
    /// Otherwise the colour comes from the provider's place in the
    /// companion's list, not from a case written here: the list is the
    /// companion's to grow, and a service it adds should arrive with a colour
    /// of its own rather than a default grey.
    private var providerKeyTint: Color {
        if model.isProviderReady(model.transcriptionProvider) == false {
            return .red
        }
        let palette: [Color] = [.mint, .indigo, .purple, .teal, .orange, .brown]
        let place = model.knownProviders.firstIndex(of: model.transcriptionProvider) ?? 0
        return palette[place % palette.count]
    }

    private var statusLine: some View {
        Text(model.message.isEmpty ? "What you type goes straight to the active field on the computer" : model.message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 22)
            .multilineTextAlignment(.center)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .accessibilityIdentifier("status")
    }

    private func arrows(compact: Bool) -> some View {
        let size: CGFloat = compact ? 45 : 55
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                RemoteActionKey(
                    icon: model.isComputerMicActive ? "mic.fill" : "mic",
                    active: model.isComputerMicActive,
                    activeColor: .green,
                    width: 68,
                    height: size
                ) { Task { await model.toggleComputerMic() } }
                .accessibilityIdentifier("mic")
                .accessibilityValue(model.isComputerMicActive ? "on" : "off")
                RemoteKey(icon: "arrow.up", width: 68, height: size) { fireKey("up") }.accessibilityIdentifier("up")
                RemoteActionKey(
                    icon: "headphones",
                    active: model.isComputerSpeakerActive,
                    activeColor: .cyan,
                    width: 68,
                    height: size
                ) { Task { await model.toggleComputerSpeaker() } }
                .accessibilityIdentifier("speaker")
                .accessibilityValue(model.isComputerSpeakerActive ? "on" : "off")
            }
            HStack(spacing: 6) {
                RemoteKey(icon: "arrow.left", width: 68, height: size) { fireKey("left") }.accessibilityIdentifier("left")
                RemoteKey(icon: "arrow.down", width: 68, height: size) { fireKey("down") }.accessibilityIdentifier("down")
                RemoteKey(icon: "arrow.right", width: 68, height: size) { fireKey("right") }.accessibilityIdentifier("right")
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        // Its own height and nothing more. The trackpad underneath is the one
        // flexible row now, so this block stays put instead of floating on
        // whatever space was left over.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The gap between the arrow keys and the modifier row, turned into a
    /// trackpad. It is the only row that stretches, so it grows into exactly
    /// what the fixed rows leave behind.
    ///
    /// While the keyboard is up that space belongs to the keyboard, and the
    /// slot becomes the place to tap to put the keyboard away - which is where
    /// the finger already is, and where the pad comes back.
    private var trackpad: some View {
        GeometryReader { pad in
            if isKeyboardVisible || pad.size.height < 78 {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            } else {
                TrackpadView()
                    .frame(width: pad.size.width, height: pad.size.height)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func modifierRow(compact: Bool) -> some View {
        HStack(spacing: 5) {
            TextKey(title: "Tab ⇥", active: false, compact: compact) { fireKey("tab") }
                .accessibilityIdentifier("key-tab")
            TextKey(title: "Alt", active: modifiers.contains("alt"), compact: compact) { toggleModifier("alt") }
                .accessibilityIdentifier("key-alt")
            TextKey(title: "Shift ⇧", active: modifiers.contains("shift"), compact: compact) { toggleModifier("shift") }
                .accessibilityIdentifier("key-shift")
            TextKey(title: "Ctrl", active: modifiers.contains("ctrl"), compact: compact) { toggleModifier("ctrl") }
                .accessibilityIdentifier("key-ctrl")
            TextKey(title: "Esc", active: false, compact: compact) { fireKey("escape") }
                .accessibilityIdentifier("key-esc")
        }
    }

    private func handleEdit(_ oldValue: String, _ newValue: String) {
        let active = activeModifiers()
        let sentAsCombo = model.queueLiveEdit(from: oldValue, to: newValue, modifiers: active)
        if sentAsCombo {
            draft = oldValue
        }
        if !active.isEmpty { modifiers.removeAll() }
    }

    private func activeModifiers() -> [String] {
        ["shift", "ctrl", "alt"].filter { modifiers.contains($0) }
    }

    private func toggleModifier(_ modifier: String) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) }
        else { modifiers.insert(modifier) }
    }

    private func fireKey(_ key: String) {
        model.sendKey(key, modifiers: activeModifiers())
        modifiers.removeAll()
    }
}

private struct HeaderButton: View {
    let icon: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.bold()).frame(width: 29, height: 29)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption2.bold())
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(red: 0.68, green: 0.77, blue: 0.88))
        .background(Color(red: 0.055, green: 0.098, blue: 0.17), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))
    }
}

private struct RemoteKey: View {
    let icon: String
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.bold()).frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .background(Color(red: 0.078, green: 0.114, blue: 0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))
    }
}

private struct RemoteActionKey: View {
    let icon: String
    let active: Bool
    var activeColor: Color = .green
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.bold()).frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : Color(red: 0.78, green: 0.83, blue: 0.9))
        .background(active ? activeColor.opacity(0.8) : Color(red: 0.078, green: 0.114, blue: 0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? activeColor : Color.white.opacity(0.1)))
    }
}

/// A modifier-row key that carries a colour of its own. Same shape as the
/// keyboard keys around it, a shade lighter, so the dictation options read as
/// settings rather than as another key to press by mistake.
private struct OptionKey: View {
    let title: String
    let tint: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.caption2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 54, height: height)
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.7)))
    }
}

private struct TextKey: View {
    let title: String
    let active: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.caption.bold())
            .frame(maxWidth: .infinity, minHeight: compact ? 37 : 43)
            .buttonStyle(.plain)
            .foregroundStyle(active ? Color.cyan.opacity(0.9) : Color(red: 0.78, green: 0.83, blue: 0.9))
            .background(active ? Color.cyan.opacity(0.16) : Color(red: 0.078, green: 0.114, blue: 0.18), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? Color.cyan.opacity(0.55) : Color.white.opacity(0.1)))
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Computer", value: model.address)
                    LabeledContent("Status", value: model.connectionLabel)
                    Button("Forget pairing", role: .destructive) {
                        model.forgetPairing()
                        dismiss()
                    }
                }
                Section("Paste button: saved texts (\(model.pasteSnippets.count) of \(PasteSnippetStore.limit))") {
                    ForEach($model.pasteSnippets) { $snippet in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                // A title like «password» or «PIN» made iOS take
                                // both fields for a password form, so a paste was
                                // refused and only the last letter stayed. An
                                // explicit type stops that guess.
                                TextField("Title", text: $snippet.title)
                                    .font(.body.bold())
                                    .textContentType(.oneTimeCode)
                                    .autocorrectionDisabled()
                                Button(role: .destructive) {
                                    model.pasteSnippets.removeAll { $0.id == snippet.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete")
                            }
                            TextField("Text to paste", text: $snippet.text, axis: .vertical)
                                .lineLimit(1...6)
                                .font(.callout)
                                .textContentType(.oneTimeCode)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(.vertical, 4)
                    }
                    if model.pasteSnippets.count < PasteSnippetStore.limit {
                        Button {
                            model.pasteSnippets.append(PasteSnippet())
                        } label: {
                            Label("Add a text", systemImage: "plus")
                        }
                    }
                    Text("The turquoise clipboard button at the top lists the filled texts; one tap types a text into the computer's active window, with no AI involved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                BuiltInAISection()
                Section {
                    LabeledContent("Computer microphone", value: model.computerMicDevice.isEmpty ? L("Off") : model.computerMicDevice)
                    LabeledContent("Computer sound", value: model.computerSpeakerDevice.isEmpty ? L("Off") : model.computerSpeakerDevice)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("The microphone key makes the iPhone the computer's microphone (it needs the free VB-CABLE driver there). The headphones key plays the computer's sound on the iPhone.")
                }
                AboutSection()
            }
            .navigationTitle("WiFiTalk")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
