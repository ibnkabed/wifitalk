import SwiftUI

/// The iPhone keyboard types straight into the computer, in any language the phone has, letter by letter.
struct KeyboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var sent = ""
    @FocusState private var focused: Bool

    private let rows: [[(LocalizedStringKey, String)]] = [
        [("Esc", "esc"), ("Tab", "tab"), ("⌫", "backspace"), ("Enter", "enter")],
        [("←", "left"), ("↑", "up"), ("↓", "down"), ("→", "right")],
        [("Copy", "ctrl+c"), ("Paste", "ctrl+v"), ("Undo", "ctrl+z"), ("Select all", "ctrl+a")],
        [("Save", "ctrl+s"), ("New tab", "ctrl+t"), ("Switch app", "alt+tab"), ("Desktop", "win+d")]
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ConnectionBar()
                    TextField("Type here — it appears on the computer", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .textInputAutocapitalization(.sentences)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        .onChange(of: text) { _, now in sendDifference(to: now) }
                    HStack {
                        Button("Clear the box") { text = ""; sent = "" }
                        Spacer()
                        Button(focused ? "Hide keyboard" : "Show keyboard") { focused.toggle() }
                    }
                    .font(.footnote).padding(.horizontal)

                    VStack(spacing: 8) {
                        ForEach(rows.indices, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(rows[r].indices, id: \.self) { c in
                                    let key = rows[r][c]
                                    Button { model.keys(key.1) } label: {
                                        Text(key.0).font(.callout).frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Sends only what changed: new letters are typed, removed ones are erased with Backspace.
    private func sendDifference(to now: String) {
        let old = sent
        sent = now
        let common = zip(old, now).prefix { $0 == $1 }.count
        let removed = old.count - common
        let added = String(now.dropFirst(common))
        var actions: [[String: Any]] = Array(repeating: ["t": "keys", "k": "backspace"], count: removed)
        if !added.isEmpty { actions.append(["t": "text", "s": added]) }
        guard !actions.isEmpty else { return }
        Task { try? await model.link.run(actions) }
    }
}
