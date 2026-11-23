import SwiftUI
import UIKit

/// The iPhone as the computer's trackpad: one finger moves, tap clicks, two-finger tap right-clicks,
/// two fingers scroll, and a long press then drag holds the left button (to drag and select).
struct TrackpadView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ConnectionBar()
                TrackpadSurface(link: model.link)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemBackground)))
                    .overlay(alignment: .bottom) {
                        Text("Move · tap to click · two-finger tap: right-click · two fingers: scroll · long press: drag")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(10)
                    }
                    .padding(.horizontal)
                HStack(spacing: 12) {
                    pad("Left", "cursorarrow.click") { model.link.send([["t": "click", "b": "left", "n": 1]]) }
                    pad("Right", "contextualmenu.and.cursorarrow") { model.link.send([["t": "click", "b": "right", "n": 1]]) }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("Trackpad")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pad(_ title: LocalizedStringKey, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.bordered)
    }
}

struct TrackpadSurface: UIViewRepresentable {
    let link: Companion

    func makeUIView(context: Context) -> TrackpadUIView {
        let v = TrackpadUIView()
        v.link = link
        return v
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) { uiView.link = link }
}

final class TrackpadUIView: UIView {
    weak var link: Companion?
    private var pendingMove = CGPoint.zero
    private var pendingScroll = CGPoint.zero
    private var dragging = false
    private var flushScheduled = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
        move.minimumNumberOfTouches = 1; move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap))
        twoTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.45
        tap.require(toFail: twoTap)
        for g in [move, scroll, tap, twoTap, hold] as [UIGestureRecognizer] { addGestureRecognizer(g) }
        move.require(toFail: hold)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Faster finger, farther pointer: a gentle acceleration curve like a laptop trackpad.
    private func accelerate(_ d: CGPoint) -> CGPoint {
        let speed = hypot(d.x, d.y)
        let gain = 1.6 + min(speed / 6, 3.0)
        return CGPoint(x: d.x * gain, y: d.y * gain)
    }

    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let a = accelerate(t)
        pendingMove.x += a.x; pendingMove.y += a.y
        scheduleFlush()
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // natural scrolling: fingers up, page up; one wheel notch is 120
        pendingScroll.x -= t.x * 6; pendingScroll.y += t.y * 6
        scheduleFlush()
    }

    @objc private func onTap() {
        haptic.impactOccurred()
        Task { @MainActor in link?.send([["t": "click", "b": "left", "n": 1]]) }
    }

    @objc private func onTwoFingerTap() {
        haptic.impactOccurred()
        Task { @MainActor in link?.send([["t": "click", "b": "right", "n": 1]]) }
    }

    /// Long press holds the left button; moving the finger drags; lifting it lets go.
    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            haptic.impactOccurred(intensity: 1)
            lastHold = g.location(in: self)
            Task { @MainActor in link?.send([["t": "down", "b": "left"]]) }
        case .changed:
            let p = g.location(in: self)
            let a = accelerate(CGPoint(x: p.x - lastHold.x, y: p.y - lastHold.y))
            lastHold = p
            pendingMove.x += a.x; pendingMove.y += a.y
            scheduleFlush()
        default:
            if dragging {
                dragging = false
                flush()
                Task { @MainActor in link?.send([["t": "up", "b": "left"]]) }
            }
        }
    }

    private var lastHold = CGPoint.zero

    /// Moves and scrolls are batched into one message every 16 ms (60 a second).
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        var actions: [[String: Any]] = []
        let dx = Int(pendingMove.x.rounded()), dy = Int(pendingMove.y.rounded())
        if dx != 0 || dy != 0 {
            actions.append(["t": "move", "dx": dx, "dy": dy])
            pendingMove.x -= CGFloat(dx); pendingMove.y -= CGFloat(dy)
        }
        let sx = Int(pendingScroll.x.rounded()), sy = Int(pendingScroll.y.rounded())
        if abs(sy) >= 20 || abs(sx) >= 20 {
            actions.append(["t": "scroll", "dx": sx, "dy": sy])
            pendingScroll = .zero
        }
        guard !actions.isEmpty else { return }
        Task { @MainActor in link?.send(actions) }
    }
}
