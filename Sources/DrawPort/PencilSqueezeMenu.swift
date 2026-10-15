import UIKit

/// iPadOS 18 has no hidden-but-active PKToolPicker (that API starts in iPadOS 26).
/// This transient, Pencil-positioned menu never installs a persistent docked toolbar.
final class PencilSqueezeMenu: UIControl {
    struct Action {
        let symbol: String
        let label: String
        let perform: () -> Void
    }

    init(in host: UIView, near location: CGPoint, actions: [Action]) {
        super.init(frame: host.bounds)
        accessibilityIdentifier = "pencilSqueezePalette"
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.18)
        addTarget(self, action: #selector(dismissMenu), for: .touchUpInside)
        let size = CGSize(width: 450, height: 300)
        let safe = host.safeAreaInsets
        let x = min(max(location.x - size.width / 2, safe.left + 4), max(safe.left + 4, host.bounds.width - safe.right - size.width - 4))
        let y = min(max(location.y - size.height / 2, safe.top + 4), max(safe.top + 4, host.bounds.height - safe.bottom - size.height - 4))
        let panel = UIView(frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
        panel.accessibilityIdentifier = "squeezeToolArc"
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 13, y: 286))
        path.addArc(withCenter: CGPoint(x: 225, y: 286), radius: 212,
                    startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
        path.close()
        let fill = CAShapeLayer()
        fill.path = path.cgPath
        fill.fillColor = UIColor(white: 0.11, alpha: 0.98).cgColor
        fill.strokeColor = UIColor(white: 0.35, alpha: 1).cgColor
        fill.lineWidth = 1
        panel.layer.addSublayer(fill)
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.35
        panel.layer.shadowRadius = 18
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)
        for (index, item) in actions.enumerated() {
            let angle = CGFloat.pi + 0.13 + CGFloat(index) * (CGFloat.pi - 0.26) / CGFloat(max(actions.count - 1, 1))
            let control = UIButton(type: .system)
            var style = UIButton.Configuration.plain()
            style.image = UIImage(systemName: item.symbol)
            style.imagePlacement = .top
            style.imagePadding = 5
            style.title = item.label
            style.baseForegroundColor = .white
            control.configuration = style
            control.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            control.tintColor = .white
            control.backgroundColor = UIColor(white: 0.24, alpha: 1)
            control.layer.cornerRadius = 15
            control.accessibilityLabel = item.label
            control.frame = CGRect(x: 225 + 175 * cos(angle) - 34,
                                   y: 280 + 175 * sin(angle) - 31, width: 68, height: 66)
            control.addAction(UIAction { [weak self] _ in
                self?.removeFromSuperview()
                item.perform()
            }, for: .touchUpInside)
            panel.addSubview(control)
        }
        addSubview(panel)
        host.addSubview(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func dismissMenu() { removeFromSuperview() }
}
