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
            arc.shadowOpacity = 0.34
            arc.shadowRadius = 12
            arc.shadowOffset = CGSize(width: 0, height: 7)
            layer.addSublayer(arc)
        }
        toolArc.lineWidth = 62
        colorArc.lineWidth = 54
        makeControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The system canvas retains Pencil/finger input beyond the two curved bands.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for control in controls.reversed() where !control.isHidden && control.frame.insetBy(dx: -5, dy: -5).contains(point) {
            return control
        }
        return nil
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
            let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
            button.setImage(image, for: .normal)
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
            swatch.layer.cornerRadius = 16
            swatch.layer.borderColor = UIColor(white: 0.45, alpha: 1).cgColor
            swatch.layer.borderWidth = 1.4
            swatch.isUserInteractionEnabled = false
            swatch.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
            button.addSubview(swatch)
            if selectedColor == index {
                button.layer.cornerRadius = 23
                button.layer.borderWidth = 3
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
        // Mirror around the Pencil near the leading/top edge instead of putting
        // the arc outside the iPad. Never scale the icons or cover the entire page.
        let mirrorX = requestedAnchor.x < bounds.midX
        let mirrorY = requestedAnchor.y < 270
        let center = CGPoint(
            x: min(max(requestedAnchor.x, mirrorX ? 70 : 245), bounds.width - (mirrorX ? 245 : 145)),
            y: min(max(requestedAnchor.y, mirrorY ? 75 : 260), bounds.height - (mirrorY ? 260 : 90))
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
        toolArc.path = path(radius: 164, start: 160, end: 316).cgPath
        colorArc.path = path(radius: 228, start: 200, end: 248).cgPath
        let angles: [CGFloat] = [164, 180, 196, 212, 228, 244, 260, 276, 296, 314]
        for (index, angle) in angles.enumerated() {
            let location = point(radius: 164, degrees: angle)
            controls[index].frame = CGRect(x: location.x - 23, y: location.y - 23, width: 46, height: 46)
        }
        for (offset, angle) in ([201.0, 216.0, 232.0, 247.0] as [CGFloat]).enumerated() {
            let location = point(radius: 228, degrees: angle)
            controls[10 + offset].frame = CGRect(x: location.x - 23, y: location.y - 23, width: 46, height: 46)
        }
    }
}
