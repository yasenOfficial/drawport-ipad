import UIKit

/// Squeeze-only tool overlay. It never registers an on-screen PKToolPicker and
/// never intercepts touches on the paper outside its actual controls.
final class PencilRadialPalette: UIView {
    enum Action {
        case undo, redo, pen, highlighter, eraser, lasso, hand, shapes, addPage, overview
        case color(Int)
    }

    var onAction: ((Action) -> Void)?
    private let toolArc = CAShapeLayer()
    private let colorArc = CAShapeLayer()
    private var controls: [UIButton] = []
    private var requestedAnchor: CGPoint
    private let selectedTool: Int
    private let selectedColor: Int
    private let colors: [UIColor]

    init(frame: CGRect, anchor: CGPoint, selectedTool: Int, selectedColor: Int, colors: [UIColor]) {
        requestedAnchor = anchor
        self.selectedTool = selectedTool
        self.selectedColor = selectedColor
        self.colors = colors
        super.init(frame: frame)
        accessibilityIdentifier = "pencilSqueezePalette"
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        for arc in [toolArc, colorArc] {
            arc.fillColor = UIColor.clear.cgColor
            arc.strokeColor = UIColor(white: 0.105, alpha: 1).cgColor
            arc.lineCap = .round
            arc.shadowColor = UIColor.black.cgColor
            arc.shadowOpacity = 0.30
            arc.shadowRadius = 6
            arc.shadowOffset = CGSize(width: 0, height: 3)
            layer.addSublayer(arc)
        }
        toolArc.lineWidth = 31
        colorArc.lineWidth = 27
        makeControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The system canvas retains Pencil/finger input beyond the two curved bands.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.05 else { return nil }
        for control in controls.reversed() where !control.isHidden && control.frame.insetBy(dx: -2, dy: -2).contains(point) {
            return control
        }
        return nil
    }

    func appear() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let originalFrame = frame
        layer.anchorPoint = CGPoint(x: min(1, max(0, requestedAnchor.x / bounds.width)),
                                    y: min(1, max(0, requestedAnchor.y / bounds.height)))
        frame = originalFrame
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
        UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.45, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func dismiss(animated: Bool = true) {
        guard animated else { removeFromSuperview(); return }
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    private func makeControls() {
        let tools: [(Action, String, String, Bool)] = [
            (.undo, "arrow.uturn.backward", "Undo", false),
            (.redo, "arrow.uturn.forward", "Redo", false),
            (.pen, "pencil.tip", "Pen", selectedTool == 0),
            (.highlighter, "highlighter", "Highlighter", selectedTool == 2),
            (.eraser, "eraser.fill", "Eraser", selectedTool == 1),
            (.lasso, "lasso", "Selection", selectedTool == 3),
            (.hand, "hand.draw", "Hand", false),
            (.shapes, "scribble.variable", "Shapes", false),
            (.addPage, "plus.circle", "New page", false),
            (.overview, "square.grid.2x2", "Page overview", false)
        ]
        for (action, symbol, label, selected) in tools {
            let button = UIButton(type: .system)
            let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            button.setImage(image, for: .normal)
            button.contentHorizontalAlignment = .center
            button.contentVerticalAlignment = .center
            button.tintColor = selected ? UIColor(red: 0.13, green: 0.44, blue: 1, alpha: 1) : .white
            button.accessibilityLabel = label == "Hand" ? "Hand navigation unavailable" : label
            button.accessibilityIdentifier = "pencilPalette.\(label.replacingOccurrences(of: " ", with: ""))"
            if label == "Hand" {
                button.isEnabled = false
                button.alpha = 0.48
            } else {
                button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            }
            addSubview(button)
            controls.append(button)
        }
        // The reference has a second, shorter crescent with four color wells.
        for (index, label) in [(0, "Black"), (5, "Red"), (2, "Green"), (6, "Blue")] {
            let button = UIButton(type: .system)
            let swatch = UIView()
            swatch.backgroundColor = colors.indices.contains(index) ? colors[index] : .black
            swatch.layer.cornerRadius = 9
            swatch.layer.borderColor = UIColor(white: 0.45, alpha: 1).cgColor
            swatch.layer.borderWidth = 0.8
            swatch.isUserInteractionEnabled = false
            // Both the swatch and its selection ring share the same center.
            swatch.frame = CGRect(x: 4, y: 4, width: 18, height: 18)
            button.addSubview(swatch)
            if selectedColor == index {
                button.layer.cornerRadius = 13
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor(red: 0.16, green: 0.53, blue: 1, alpha: 1).cgColor
            }
            button.accessibilityLabel = "\(label) ink"
            button.accessibilityIdentifier = "pencilPalette.\(label)"
            button.addAction(UIAction { [weak self] _ in self?.onAction?(.color(index)) }, for: .touchUpInside)
            addSubview(button)
            controls.append(button)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, controls.count == 14 else { return }
        // Keep the 1:2 geometry coherent, including the safe-area clamping.
        // The icons and wells are placed on the exact centerlines of both bands.
        let mirrorX = requestedAnchor.x < bounds.midX
        let mirrorY = requestedAnchor.y < 150
        let center = CGPoint(
            x: min(max(requestedAnchor.x, mirrorX ? 48 : 141), bounds.width - (mirrorX ? 141 : 82)),
            y: min(max(requestedAnchor.y, mirrorY ? 68 : 146), bounds.height - (mirrorY ? 146 : 54))
        )
        func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + (mirrorX ? -1 : 1) * radius * cos(angle),
                           y: center.y + (mirrorY ? -1 : 1) * radius * sin(angle))
        }
        func path(radius: CGFloat, start: Int, end: Int) -> UIBezierPath {
            let result = UIBezierPath()
            for degree in stride(from: start, through: end, by: 2) {
                let location = point(radius: radius, degrees: CGFloat(degree))
                if degree == start { result.move(to: location) }
                else { result.addLine(to: location) }
            }
            return result
        }
        toolArc.path = path(radius: 82, start: 160, end: 316).cgPath
        colorArc.path = path(radius: 114, start: 200, end: 248).cgPath
        let angles: [CGFloat] = [164, 180, 196, 212, 228, 244, 260, 276, 296, 314]
        let scale = UIScreen.main.scale
        func centeredFrame(_ location: CGPoint) -> CGRect {
            CGRect(x: ((location.x - 13) * scale).rounded() / scale,
                   y: ((location.y - 13) * scale).rounded() / scale,
                   width: 26, height: 26)
        }
        for (index, angle) in angles.enumerated() {
            controls[index].frame = centeredFrame(point(radius: 82, degrees: angle))
        }
        for (offset, angle) in ([201.0, 216.0, 232.0, 247.0] as [CGFloat]).enumerated() {
            controls[10 + offset].frame = centeredFrame(point(radius: 114, degrees: angle))
        }
    }
}
