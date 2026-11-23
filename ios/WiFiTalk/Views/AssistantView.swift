import SwiftUI

/// Talk to the computer: say or type what you want, the phone's AI turns it into actions, the computer does them.
struct AssistantView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var hybrid = FirebaseHybrid.shared
    @State private var dictate = false
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ConnectionBar()
                    Picker("Mode", selection: $dictate) {
                        Text("Command").tag(false)
                        Text("Dictation").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    MicButton(dictate: dictate)

                    Text(hint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)

                    if !dictate {
                        HStack {
                            TextField("Or type a request…", text: $typed, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(send)
                            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                        }
                        .padding(.horizontal)
                    }

                    if model.busy { ProgressView("Thinking…") }
                    if let m = model.message {
                        Text(m).font(.callout).foregroundStyle(.red).padding(.horizontal).multilineTextAlignment(.center)
                    }
                    if let plan = model.plan { PlanCard(plan: plan) }
                }
                .padding(.vertical)
            }
            .navigationTitle("Assistant")
            .confirmationDialog("Do this on the computer?", isPresented: Binding(
                get: { model.pendingConfirmation != nil }, set: { if !$0 { model.pendingConfirmation = nil } }),
                titleVisibility: .visible) {
                Button("Yes, do it", role: .destructive) {
                    if let p = model.pendingConfirmation { Task { await model.execute(p) } }
                }
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
            } message: {
                Text(model.pendingConfirmation?.actions.map(Assistant.describe).joined(separator: "\n") ?? "")
            }
        }
    }

    private var hint: String {
        dictate ? String(localized: "Speak, and your words are typed on the computer where the cursor is.")
                : String(localized: "Try: “Open Chrome and search for weather in Riyadh”, “Write a short thank-you email to my team”, “Volume down”, “Lock the computer”.")
    }

    private func send() {
        let text = typed
        typed = ""
        Task { await model.ask(text) }
    }
}

/// Tap to start listening, tap again to send.
private struct MicButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var listener: SpeechListener
    let dictate: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if listener.listening { await model.finishListening(dictate: dictate) }
                    else { await model.startListening() }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(listener.listening ? Color.red.gradient : Color.accentColor.gradient)
                        .frame(width: 120, height: 120)
                        .shadow(radius: listener.listening ? 12 : 4)
                    Image(systemName: listener.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .accessibilityLabel(listener.listening ? Text("Stop and send") : Text("Speak"))

            if listener.listening || !listener.text.isEmpty {
                Text(listener.text.isEmpty ? String(localized: "Listening…") : listener.text)
                    .font(.body).multilineTextAlignment(.center).padding(.horizontal)
            }
            if listener.listening {
                Label(listener.onDevice ? String(localized: "Speech recognized on this iPhone") : String(localized: "Speech recognized by Apple"),
                      systemImage: listener.onDevice ? "iphone" : "waveform")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// What the assistant understood and what the computer did, with the engine that answered.
private struct PlanCard: View {
    @EnvironmentObject var model: AppModel
    let plan: Assistant.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.say.isEmpty { Text(plan.say).font(.headline) }
            ForEach(Array(plan.actions.enumerated()), id: \.offset) { i, action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: i < model.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(i < model.done ? Color.green : Color.secondary)
                    Text(Assistant.describe(action)).font(.callout)
                }
            }
            if let engine = model.planEngine { EngineBadge(engine: engine) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

/// Which engine understood the request: Apple's model on this iPhone, or Gemini in the cloud through Firebase.
struct EngineBadge: View {
    let engine: FirebaseHybrid.Engine

    var body: some View {
        Label(engine == .onDevice ? String(localized: "Understood on this iPhone (Apple on-device model)")
                                  : String(localized: "Understood by Gemini in the cloud (Firebase AI Logic)"),
              systemImage: engine == .onDevice ? "iphone" : "cloud")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
