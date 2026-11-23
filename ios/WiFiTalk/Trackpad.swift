import QuartzCore
import SwiftUI
import UIKit

/// The on-screen trackpad that fills the gap between the arrow keys and the
/// modifier row.
///
/// Touches are read straight from `UIView` rather than through
/// `UIPanGestureRecognizer`. A pan recognizer refuses to begin until the finger
/// has travelled its own slop distance, and on a pad this size that dead zone
/// at the start of every stroke is the difference between a pointer that
/// answers the finger and one that feels stuck. Reading the touches directly
/// also keeps the tap, the two-finger tap and the drag lock in one place, where
/// they cannot fight each other over which recognizer wins.
struct TrackpadView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTouching = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.055, green: 0.086, blue: 0.145))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isTouching ? Color.cyan.opacity(0.45) : Color.white.opacity(0.1),
                            lineWidth: isTouching ? 1.4 : 1
                        )
                )
            VStack(spacing: 7) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 25, weight: .light))
                Text("Slide to move · tap = click · two fingers = scroll and right-click")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.white.opacity(isTouching ? 0.10 : 0.20))
            .allowsHitTesting(false)
            TrackpadSurface(
                onMove: { dx, dy in model.moveCursor(dx: dx, dy: dy) },
                onScroll: { dx, dy in model.scrollCursor(dx: dx, dy: dy) },
                onClick: { button in model.clickMouse(button) },
                onButton: { button, down in model.setMouseButton(button, down: down) },
                onTouchState: { touching in isTouching = touching }
            )
        }
        .animation(.easeOut(duration: 0.12), value: isTouching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trackpad")
        .accessibilityIdentifier("trackpad")
        .accessibilityHint("Slide one finger to move the pointer, tap to click, use two fingers to scroll")
    }
}

struct TrackpadSurface: UIViewRepresentable {
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onClick: (String) -> Void
    let onButton: (String, Bool) -> Void
    let onTouchState: (Bool) -> Void

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.apply(self)
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.apply(self)
    }
}

/// An exponential smoother whose cutoff frequency rises with the speed of the
/// finger it is smoothing — the one-euro filter.
///
/// A fixed smoother forces a choice between a pointer that shakes and one that
/// arrives late. This one refuses the choice at both ends. A finger the user
/// believes is still is not still: the digitiser reports it wandering by a
/// fraction of a point every frame, and that wander is almost all noise, so the
/// cutoff drops and the averaging cancels it. A finger that is travelling is
/// almost all signal, so the cutoff climbs and the smoothing all but
/// disappears.
///
/// The velocity it keeps is measured over a window of raw samples rather than
/// taken from the filter's own lag, and the difference is not academic. The
/// published one-euro filter derives its speed from `raw - filtered`, which is
/// the lag itself: heavier smoothing means a larger gap, which reads as a
/// faster finger, which lifts the cutoff. Inside the filter that feedback is
/// harmless, because all it does is settle the cutoff. Handing the same number
/// to an acceleration curve is not harmless at all. Measured against synthetic
/// strokes through this exact pipeline, it over-read by a factor of seven at
/// the speeds that matter for aiming - a finger at 20 points a second read as
/// 144, one at 120 read as 473 - so the curve believed every careful little
/// correction was a sweep and geared it up to match. A 20-point nudge landed
/// 38 pixels away instead of 16, which is a pointer that will not settle on a
/// button: it sails past, comes back, and sails past again.
///
/// A plain difference across a tenth of a second of raw samples reads the
/// finger's real speed at every stroke size tested, and costs nothing at the
/// top end where the gap had been narrowest anyway.
private struct PointerFilter {
    /// Cutoff with the finger at rest, in hertz. Low enough that a resting
    /// finger's wander is averaged into nothing.
    private static let minCutoff = 0.9
    /// How fast the cutoff opens up with speed, in hertz per point per second.
    ///
    /// Large now that the speed driving it is the finger's own. Against the
    /// old self-inflating estimate a value like this would have run away.
    private static let beta = 0.16
    /// How far back the velocity looks. Long enough that a resting finger's
    /// wander divides down to a few points a second and the weighing can tell
    /// it from a deliberate crawl; short enough that the curve is already at
    /// full gain a couple of frames into a flick.
    private static let velocityWindow: CFTimeInterval = 0.11

    private var x = 0.0
    private var y = 0.0
    private var primed = false
    /// Recent raw centroids, oldest first, spanning `velocityWindow`.
    private var trail: [(time: CFTimeInterval, point: CGPoint)] = []

    /// Finger velocity per axis, in points per second.
    private(set) var velocityX = 0.0
    private(set) var velocityY = 0.0

    /// Finger speed in points per second.
    var speed: Double { hypot(velocityX, velocityY) }

    /// Starts the filter over at a known point, with no speed carried in.
    ///
    /// Called whenever the centroid moves for a reason that is not the finger
    /// travelling — a stroke beginning, a second finger landing or leaving.
    /// Without it the filter would spend the next frames chasing a jump that
    /// never happened, and the velocity window would measure that jump as
    /// speed.
    mutating func reset(to point: CGPoint, at now: CFTimeInterval) {
        x = Double(point.x)
        y = Double(point.y)
        velocityX = 0
        velocityY = 0
        trail = [(now, point)]
        primed = true
    }

    mutating func filter(_ point: CGPoint, at now: CFTimeInterval, rate: Double) -> CGPoint {
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        guard primed else {
            reset(to: point, at: now)
            return point
        }
        trail.append((now, point))
        // Two samples are kept whatever their age, so a finger that pauses and
        // sets off again is measured against where it actually paused.
        while trail.count > 2, now - trail[0].time > Self.velocityWindow {
            trail.removeFirst()
        }
        let span = now - trail[0].time
        if span > 0 {
            velocityX = (rawX - Double(trail[0].point.x)) / span
            velocityY = (rawY - Double(trail[0].point.y)) / span
        }
        // A cutoff per axis, each from its own speed. A shared cutoff taken
        // from the combined speed lets a fast sweep along one axis hold the
        // other axis wide open, so the sweep carries the whole of that axis's
        // noise with it and the pointer arrives at a height the user did not
        // choose. On a true diagonal the two speeds are equal and the two
        // cutoffs with them, so nothing is bent.
        let alphaX = Self.alpha(cutoff: Self.minCutoff + Self.beta * abs(velocityX), rate: rate)
        let alphaY = Self.alpha(cutoff: Self.minCutoff + Self.beta * abs(velocityY), rate: rate)
        x += alphaX * (rawX - x)
        y += alphaY * (rawY - y)
        return CGPoint(x: x, y: y)
    }

    private static func alpha(cutoff: Double, rate: Double) -> Double {
        1 / (1 + rate / (2 * .pi * cutoff))
    }
}

final class TrackpadUIView: UIView {
    /// Windows pixels per finger point with the finger barely moving.
    ///
    /// Under one on purpose. The pointer travelling less than the finger is
    /// what makes a small target reachable: the user spends a centimetre of
    /// pad to cross the last few pixels, and lands.
    private static let minGain = 0.75
    /// Windows pixels per finger point at the top of a sweep. One flick still
    /// has to cross a desktop the pad is a fiftieth the width of.
    private static let maxGain = 5.2
    /// Finger speed, in points per second, at which the curve has opened
    /// halfway.
    ///
    /// Moved down from 450 at the same time the curve started reading the
    /// finger's real speed rather than the filter's lag. The old speed ran
    /// several times high, which dragged the curve far up its ramp for
    /// ordinary movement; correcting the speed without moving the knee would
    /// have left a sweep landing a third of where it used to. Measured through
    /// the pipeline, this pair keeps a flick within a few per cent of what it
    /// crossed before while a careful nudge lands at half the distance it did.
    private static let gainKnee = 260.0
    /// Below roughly this speed an axis is pulled down further still. It is
    /// what is left of a resting finger's wander after the filter, and the one
    /// thing the acceleration curve alone cannot tell apart from a deliberate
    /// crawl. Attenuation rather than a threshold: nothing is ever blocked, so
    /// there is no dead zone in front of a stroke, and it lifts within a frame
    /// or two of the finger actually setting off.
    ///
    /// Weighed per axis rather than on the speed of the stroke as a whole. A
    /// thumb sweeping across a pad this small pivots at its base, so a sweep
    /// the user means as horizontal arcs downward by a few points a second -
    /// and against the speed of the sweep that arc reads as deliberate and
    /// passes at full gain, while the slow upward nudge meant to undo it reads
    /// as noise and is squelched. On a 720-line screen with a 48-pixel
    /// taskbar, a few points of arc is the difference between landing on a
    /// tray icon and sliding under the row of them.
    private static let stillnessSpeed = 9.0
    /// Finger points per wheel notch.
    private static let scrollDivisor = 38.0
    /// Movement smaller than this is held back rather than sent.
    ///
    /// Not a dead zone: what is held is added to the next packet, so no travel
    /// is lost — and it is held across the lift of the finger too, for the
    /// same reason the companion holds its own fraction. It exists because the
    /// pump fires a request per call, and a resting hand would otherwise keep
    /// the companion answering packets worth a hundredth of a pixel all day.
    private static let moveFloor = 0.2
    private static let scrollFloor = 0.04
    /// A touch that moved less than this and lasted less than `tapDuration` is
    /// a tap, not a stroke.
    private static let tapSlop: CGFloat = 12
    private static let tapDuration: CFTimeInterval = 0.35
    /// Placing the finger back down this soon after a tap, near where the tap
    /// landed, holds the left button - the drag every trackpad does.
    private static let dragLockWindow: CFTimeInterval = 0.35
    private static let dragLockRadius: CGFloat = 44

    private var onMove: (Double, Double) -> Void = { _, _ in }
    private var onScroll: (Double, Double) -> Void = { _, _ in }
    private var onClick: (String) -> Void = { _ in }
    private var onButton: (String, Bool) -> Void = { _, _ in }
    private var onTouchState: (Bool) -> Void = { _ in }

    private var activeTouches: Set<UITouch> = []
    private var filter = PointerFilter()
    private var lastCentroid: CGPoint = .zero
    private var lastMoveTime: CFTimeInterval = 0
    private var strokeStartedAt: CFTimeInterval = 0
    private var travelled: CGFloat = 0
    private var pendingMoveX = 0.0
    private var pendingMoveY = 0.0
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var peakTouchCount = 0
    private var isDragging = false
    private var lastTapEndedAt: CFTimeInterval = 0
    private var lastTapLocation: CGPoint = .zero

    func apply(_ surface: TrackpadSurface) {
        onMove = surface.onMove
        onScroll = surface.onScroll
        onClick = surface.onClick
        onButton = surface.onButton
        onTouchState = surface.onTouchState
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = activeTouches.isEmpty
        activeTouches.formUnion(touches)
        let now = CACurrentMediaTime()
        if wasEmpty {
            strokeStartedAt = now
            travelled = 0
            peakTouchCount = 0
            onTouchState(true)
            let start = centroid()
            if now - lastTapEndedAt < Self.dragLockWindow,
               hypot(start.x - lastTapLocation.x, start.y - lastTapLocation.y) < Self.dragLockRadius {
                isDragging = true
                onButton("left", true)
            }
        }
        peakTouchCount = max(peakTouchCount, activeTouches.count)
        // A finger arriving mid-stroke moves the centroid on its own. Rebasing
        // here is what stops the pointer from jumping the moment the second
        // finger lands.
        rebase()
        lastMoveTime = now
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !activeTouches.isEmpty else { return }
        let now = CACurrentMediaTime()
        // Clamped at both ends: two events inside one frame would otherwise
        // claim an impossible sample rate, and a stall would claim the finger
        // had been still for as long as the app was away.
        let elapsed = min(max(now - lastMoveTime, 1.0 / 240.0), 1.0 / 20.0)
        lastMoveTime = now
        let current = filter.filter(centroid(), at: now, rate: 1 / elapsed)
        let dx = Double(current.x - lastCentroid.x)
        let dy = Double(current.y - lastCentroid.y)
        lastCentroid = current
        travelled += CGFloat(hypot(dx, dy))
        guard dx != 0 || dy != 0 else { return }

        let weightX = Self.axisWeight(forSpeed: abs(filter.velocityX))
        let weightY = Self.axisWeight(forSpeed: abs(filter.velocityY))

        if activeTouches.count >= 2 {
            // Natural direction: the content follows the finger, so a finger
            // moving down turns into a wheel notch upward. The same weighing
            // as the pointer, and for the same reason: a page scrolled up
            // should not drift sideways because the two fingers fanned a
            // little on the way.
            pendingScrollX -= dx * weightX / Self.scrollDivisor
            pendingScrollY += dy * weightY / Self.scrollDivisor
            if hypot(pendingScrollX, pendingScrollY) >= Self.scrollFloor {
                onScroll(pendingScrollX, pendingScrollY)
                pendingScrollX = 0
                pendingScrollY = 0
            }
            return
        }

        // Pointer acceleration lives here rather than in Windows: the companion
        // places the pointer absolutely so the system curve never runs, and a
        // curve applied where the touch timing is known is the accurate one.
        let acceleration = Self.acceleration(forSpeed: filter.speed)
        pendingMoveX += dx * acceleration * weightX
        pendingMoveY += dy * acceleration * weightY
        if hypot(pendingMoveX, pendingMoveY) >= Self.moveFloor {
            onMove(pendingMoveX, pendingMoveY)
            pendingMoveX = 0
            pendingMoveY = 0
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    /// The acceleration curve, in Windows pixels per finger point. Opens from
    /// `minGain` up to `maxGain` as the sweep gets faster, on a smooth shape
    /// with no corner the finger can feel.
    ///
    /// Read from the speed of the stroke as a whole, never per axis. Gearing
    /// the two axes differently would bend a diagonal into a curve.
    static func acceleration(forSpeed speed: Double) -> Double {
        let squared = speed * speed
        return minGain + (maxGain - minGain) * squared / (squared + gainKnee * gainKnee)
    }

    /// How much of one axis's movement is the user rather than the hand, from
    /// that axis's own speed. The same smooth shape as the acceleration curve,
    /// closing towards zero where the only thing moving is noise or the arc of
    /// a pivoting thumb.
    ///
    /// A diagonal survives this untouched: equal speeds on the two axes give
    /// equal weights, so the direction is preserved exactly. Only a stroke
    /// that is mostly one axis is trimmed on the other, which is the whole
    /// point of weighing them apart.
    static func axisWeight(forSpeed speed: Double) -> Double {
        let squared = speed * speed
        return squared / (squared + stillnessSpeed * stillnessSpeed)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        activeTouches.subtract(touches)
        guard activeTouches.isEmpty else {
            // Fingers of a two-finger gesture never leave together. Rebase so
            // the survivor does not drag the pointer across the screen.
            rebase()
            lastMoveTime = CACurrentMediaTime()
            return
        }
        let now = CACurrentMediaTime()
        onTouchState(false)
        if isDragging {
            isDragging = false
            onButton("left", false)
        } else if !cancelled,
                  travelled < Self.tapSlop,
                  now - strokeStartedAt < Self.tapDuration {
            if peakTouchCount >= 2 {
                onClick("right")
            } else {
                onClick("left")
                lastTapEndedAt = now
                lastTapLocation = lastCentroid
            }
        }
        peakTouchCount = 0
        travelled = 0
        // Nothing sub-pixel is thrown away here, on either side of the wire.
        // An earlier build sent the companion an end event to drop the
        // fraction it carries, on the reasoning that the fraction belonged to
        // the stroke that had finished. Measured, that reasoning cost the user
        // the whole of a careful aim: six two-point nudges in a row, the way
        // anyone closes the last few pixels onto a button, delivered zero
        // pixels, because each nudge is worth less than a whole pixel and each
        // lift threw the remainder away. Carried instead, the same six nudges
        // deliver five pixels. The fraction is under one pixel and is only
        // ever spent in the direction it was gathered, so carrying it costs
        // nothing anyone can see.
    }

    private func rebase() {
        let point = centroid()
        filter.reset(to: point, at: CACurrentMediaTime())
        lastCentroid = point
    }

    private func centroid() -> CGPoint {
        guard !activeTouches.isEmpty else { return lastCentroid }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for touch in activeTouches {
            let point = touch.location(in: self)
            x += point.x
            y += point.y
        }
        let count = CGFloat(activeTouches.count)
        return CGPoint(x: x / count, y: y / count)
    }
}
