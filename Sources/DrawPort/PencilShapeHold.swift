import UIKit

/// Notices a stationary Pencil at the END of a stroke without stealing the
/// touches PencilKit needs to finish the ink. Recognition is opt-in per stroke.
final class PencilShapeHold: UIGestureRecognizer {
    var onHold: (() -> Void)?
    var onMoveAfterHold: (() -> Void)?
    private var timer: Timer?
    private var lastPoint: CGPoint?
    private var didFire = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private func resetTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.48, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible, !self.didFire else { return }
            self.didFire = true
            self.onHold?()
            self.state = .began
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .pencil,
              let view else { state = .failed; return }
        didFire = false
        lastPoint = touch.location(in: view)
        resetTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if let lastPoint, hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 7 {
            self.lastPoint = point
            if didFire { onMoveAfterHold?(); state = .changed }
            else { resetTimer() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        state = didFire ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        state = .cancelled
    }

    override func reset() {
        timer?.invalidate()
        timer = nil
        lastPoint = nil
        didFire = false
    }
}
