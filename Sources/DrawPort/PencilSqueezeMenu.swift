import UIKit

/// iPadOS 18 does not expose the hidden-but-active native picker (iPadOS 26+).
/// A transient, Pencil-positioned pair of arcs keeps the page free of docked UI.
final class PencilSqueezeMenu: UIControl {
    struct Action {
        let symbol: String
        let label: String
        let selected: Bool
        let perform: () -> Void
    }

    struct Swatch {
        let color: UIColor
        let label: String
        let selected: Bool
        let select: () -> Void
        let configure: () -> Void
    }

    private let swatches: [Swatch]
    private let designSize = CGSize(width: 560, height: 392)

    init(in host: UIView, near location: CGPoint, actions: [Action], swatches: [Swatch]) {
        self.swatches = swatches
        super.init(frame: host.bounds)
        accessibilityIdentifier = "pencilSqueezePalette"
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        addTarget(self, action: #selector(dismissMenu), for: .touchUpInside)

        let safe = host.safeAreaInsets
        let availableWidth = max(1, host.bounds.width - safe.left - safe.right - 20)
        let availableHeight = max(1, host.bounds.height - safe.top - safe.bottom - 20)
        let scale = min(1, availableWidth / designSize.width, availableHeight / designSize.height)
        let width = designSize.width * scale
        let height = designSize.height * scale
        // Keep the left/color side close to the Pencil tip without clipping a screen edge.
        let x = min(max(location.x - 135 * scale, safe.left + 10),
                    max(safe.left + 10, host.bounds.width - safe.right - width - 10))
        let y = min(max(location.y - 315 * scale, safe.top + 10),
                    max(safe.top + 10, host.bounds.height - safe.bottom - height - 10))
        let panel = UIView(frame: CGRect(origin: .zero, size: designSize))
        panel.accessibilityIdentifier = "squeezeToolArc"
        panel.backgroundColor = .clear
        panel.layer.masksToBounds = false

        let center = CGPoint(x: 322, y: 346)
        addArc(to: panel, center: center, radius: 300, start: .pi + 0.28,
               end: 1.5 * .pi + 0.05, thickness: 65)
        addArc(to: panel, center: center, radius: 215, start: .pi + 0.14,
               end: 2 * .pi - 0.40, thickness: 86)

        for (index, swatch) in swatches.enumerated() {
            let fraction = CGFloat(index) / CGFloat(max(swatches.count - 1, 1))
            let angle = CGFloat.pi + 0.28 + fraction * (1.5 * CGFloat.pi + 0.05 - CGFloat.pi - 0.28)
            let point = CGPoint(x: center.x + 300 * cos(angle), y: center.y + 300 * sin(angle))
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)
            button.backgroundColor = .clear
            button.layer.cornerRadius = 24
            button.layer.borderWidth = swatch.selected ? 3 : 0
            button.layer.borderColor = UIColor.systemBlue.cgColor
            let dot = UIView(frame: CGRect(x: 8, y: 8, width: 32, height: 32))
            dot.isUserInteractionEnabled = false
            dot.backgroundColor = swatch.color
            dot.layer.cornerRadius = 16
            dot.layer.borderWidth = 1
            dot.layer.borderColor = UIColor(white: 0.58, alpha: 1).cgColor
            button.addSubview(dot)
            button.accessibilityLabel = swatch.label
            button.accessibilityValue = swatch.selected ? "Selected" : "Not selected"
            button.tag = index
            button.addAction(UIAction { [weak self] _ in
                self?.removeFromSuperview()
                swatch.select()
            }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(configureSwatch(_:)))
            hold.minimumPressDuration = 0.45
            button.addGestureRecognizer(hold)
            panel.addSubview(button)
        }
        for (index, item) in actions.enumerated() {
            let fraction = CGFloat(index) / CGFloat(max(actions.count - 1, 1))
            let angle = CGFloat.pi + 0.14 + fraction * (CGFloat.pi - 0.54)
            let point = CGPoint(x: center.x + 215 * cos(angle), y: center.y + 215 * sin(angle))
            let button = UIButton(type: .system)
            button.frame = CGRect(x: point.x - 25, y: point.y - 25, width: 50, height: 50)
            button.accessibilityLabel = item.label
            button.accessibilityValue = item.selected ? "Selected" : "Not selected"
            let icon = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium))
            button.setImage(icon ?? UIImage(systemName: "circle"), for: .normal)
            button.tintColor = item.selected ? UIColor.systemBlue : .white
            button.addAction(UIAction { [weak self] _ in
                self?.removeFromSuperview()
                item.perform()
            }, for: .touchUpInside)
            panel.addSubview(button)
        }
        // Transform about the center so the designed arcs keep their geometry in Split View.
        panel.center = CGPoint(x: x + width / 2, y: y + height / 2)
        panel.transform = CGAffineTransform(scaleX: scale, y: scale)
        addSubview(panel)
        host.addSubview(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addArc(to panel: UIView, center: CGPoint, radius: CGFloat,
                        start: CGFloat, end: CGFloat, thickness: CGFloat) {
        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: start, endAngle: end, clockwise: true)
        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = UIColor(white: 0.12, alpha: 0.98).cgColor
        shape.lineWidth = thickness
        shape.lineCap = .round
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.28
        shape.shadowRadius = 12
        shape.shadowOffset = CGSize(width: 0, height: 6)
        panel.layer.addSublayer(shape)
    }

    @objc private func configureSwatch(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton,
              swatches.indices.contains(button.tag) else { return }
        let action = swatches[button.tag].configure
        removeFromSuperview()
        action()
    }

    @objc private func dismissMenu() { removeFromSuperview() }
}
