import UIKit

/// Squeeze-only tool overlay: no persistent dock, and paper outside the controls
/// keeps receiving Pencil and finger touches.
final class PencilRadialPalette: UIView {
    enum Action {
        case undo, redo, pen, highlighter, eraser, lasso
        case shapes, ruler, addPage, overview
        case color(Int)
    }

    enum ExtraTool: String, CaseIterable {
        case shapes, ruler, addPage, overview

        var title: String {
            switch self {
            case .shapes: "Shapes"
            case .ruler: "Ruler"
            case .addPage: "New page"
            case .overview: "Page overview"
            }
        }
        var symbol: String {
            switch self {
            case .shapes: "square.on.circle"
            case .ruler: "ruler"
            case .addPage: "plus.square"
            case .overview: "square.grid.2x2"
            }
        }
        var action: Action {
            switch self {
            case .shapes: .shapes
            case .ruler: .ruler
            case .addPage: .addPage
            case .overview: .overview
            }
        }

        static func saved() -> [ExtraTool] {
            let names = UserDefaults.standard.stringArray(forKey: "pencilRadialExtraTools") ?? []
            return allCases.filter { names.contains($0.rawValue) }
        }
        static func save(_ selected: Set<ExtraTool>) {
            UserDefaults.standard.set(allCases.filter { selected.contains($0) }.map(\.rawValue),
                                      forKey: "pencilRadialExtraTools")
        }
    }

    var onAction: ((Action) -> Void)?
    var onCustomize: ((UIView) -> Void)?
    private let toolArc = CAShapeLayer()
    private let colorArc = CAShapeLayer()
    private var toolButtons: [UIButton] = []
    private var colorButtons: [UIButton] = []
    private var extraTools: [ExtraTool]
    private let requestedAnchor: CGPoint
    private var selectedTool: Int
    private var selectedColor: Int
    private var shapesSelected: Bool
    private var rulerSelected: Bool
    private let colors: [UIColor]

    init(frame: CGRect, anchor: CGPoint, selectedTool: Int, selectedColor: Int,
         shapesSelected: Bool, rulerSelected: Bool, colors: [UIColor], extraTools: [ExtraTool]) {
        requestedAnchor = anchor
        self.selectedTool = selectedTool
        self.selectedColor = selectedColor
        self.shapesSelected = shapesSelected
        self.rulerSelected = rulerSelected
        self.colors = colors
        self.extraTools = extraTools
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
            arc.shadowRadius = 8
            arc.shadowOffset = CGSize(width: 0, height: 4)
            layer.addSublayer(arc)
        }
        toolArc.lineWidth = 40
        colorArc.lineWidth = 34
        makeToolButtons()
        makeColorButtons()
        updateSelection(tool: selectedTool, color: selectedColor,
                        shapes: shapesSelected, ruler: rulerSelected)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // A transparent full-screen host must not steal strokes outside the arc.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.05 else { return nil }
        for button in (toolButtons + colorButtons).reversed()
            where !button.isHidden && button.frame.insetBy(dx: -3, dy: -3).contains(point) {
            return button
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
        transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.84,
                       initialSpringVelocity: 0.42, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func dismiss(animated: Bool = true) {
        guard animated else { removeFromSuperview(); return }
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    func updateExtras(_ tools: [ExtraTool]) {
        extraTools = tools
        for button in toolButtons { button.removeFromSuperview() }
        toolButtons.removeAll()
        makeToolButtons()
        updateSelection(tool: selectedTool, color: selectedColor,
                        shapes: shapesSelected, ruler: rulerSelected)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func updateSelection(tool: Int, color: Int, shapes: Bool, ruler: Bool) {
        selectedTool = tool
        selectedColor = color
        shapesSelected = shapes
        rulerSelected = ruler
        for (index, button) in toolButtons.enumerated() {
            let selected: Bool
            switch index {
            case 2: selected = tool == 0 && !shapes
            case 3: selected = tool == 2 && !shapes
            case 4: selected = tool == 1
            case 5: selected = tool == 3
            default:
                let extraIndex = index - 6
                selected = extraTools.indices.contains(extraIndex)
                    && ((extraTools[extraIndex] == .shapes && shapes)
                        || (extraTools[extraIndex] == .ruler && ruler))
            }
            button.tintColor = selected ? UIColor(red: 0.13, green: 0.44, blue: 1, alpha: 1) : .white
        }
        for (index, button) in colorButtons.enumerated() {
            let ink = [0, 5, 2, 6][index]
            button.layer.borderWidth = color == ink ? 2.5 : 0
            button.layer.borderColor = UIColor(red: 0.16, green: 0.53, blue: 1, alpha: 1).cgColor
        }
    }

    private func makeToolButtons() {
        var tools: [(Action, String, String, Bool)] = [
            (.undo, "arrow.uturn.backward", "Undo", false),
            (.redo, "arrow.uturn.forward", "Redo", false),
            (.pen, "pencil.tip", "Pen", selectedTool == 0),
            (.highlighter, "highlighter", "Highlighter", selectedTool == 2),
            (.eraser, "eraser.fill", "Eraser", selectedTool == 1),
            (.lasso, "lasso", "Selection", selectedTool == 3)
        ]
        tools += extraTools.map { ($0.action, $0.symbol, $0.title, false) }
        for (action, symbol, label, selected) in tools {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            button.contentHorizontalAlignment = .center
            button.contentVerticalAlignment = .center
            button.tintColor = selected ? UIColor(red: 0.13, green: 0.44, blue: 1, alpha: 1) : .white
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "pencilPalette.\(label.replacingOccurrences(of: " ", with: ""))"
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            addSubview(button)
            toolButtons.append(button)
        }
        let plus = UIButton(type: .system)
        plus.setImage(UIImage(systemName: "plus.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        plus.tintColor = .white
        plus.accessibilityLabel = "Add popup tools"
        plus.accessibilityIdentifier = "pencilPalette.AddTools"
        plus.addAction(UIAction { [weak self, weak plus] _ in
            guard let self, let plus else { return }
            self.onCustomize?(plus)
        }, for: .touchUpInside)
        addSubview(plus)
        toolButtons.append(plus)
    }

    private func makeColorButtons() {
        for (index, label) in [(0, "Black"), (5, "Red"), (2, "Green"), (6, "Blue")] {
            let button = UIButton(type: .system)
            let swatch = UIView()
            swatch.backgroundColor = colors.indices.contains(index) ? colors[index] : .black
            swatch.layer.cornerRadius = 12
            swatch.layer.borderColor = UIColor(white: 0.45, alpha: 1).cgColor
            swatch.layer.borderWidth = 1
            swatch.isUserInteractionEnabled = false
            swatch.frame = CGRect(x: 5, y: 5, width: 24, height: 24)
            button.addSubview(swatch)
            if selectedColor == index {
                button.layer.cornerRadius = 17
                button.layer.borderWidth = 2.5
                button.layer.borderColor = UIColor(red: 0.16, green: 0.53, blue: 1, alpha: 1).cgColor
            }
            button.accessibilityLabel = "\(label) ink"
            button.accessibilityIdentifier = "pencilPalette.\(label)"
            button.addAction(UIAction { [weak self] _ in self?.onAction?(.color(index)) }, for: .touchUpInside)
            addSubview(button)
            colorButtons.append(button)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, !toolButtons.isEmpty else { return }
        // Increase the radius only if the user adds enough buttons to need it.
        let radius = CGFloat(108 + max(0, toolButtons.count - 8) * 8)
        let colorRadius = radius + 39
        let reach = colorRadius + 35
        let mirrorX = requestedAnchor.x < bounds.midX
        let mirrorY = requestedAnchor.y < reach
        let center = CGPoint(
            x: min(max(requestedAnchor.x, mirrorX ? 80 : reach), bounds.width - (mirrorX ? reach : 80)),
            y: min(max(requestedAnchor.y, mirrorY ? 80 : reach), bounds.height - (mirrorY ? reach : 65))
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
        toolArc.path = path(radius: radius, start: 160, end: 318).cgPath
        colorArc.path = path(radius: colorRadius, start: 200, end: 248).cgPath
        let scale = UIScreen.main.scale
        func centeredFrame(_ location: CGPoint) -> CGRect {
            CGRect(x: ((location.x - 17) * scale).rounded() / scale,
                   y: ((location.y - 17) * scale).rounded() / scale,
                   width: 34, height: 34)
        }
        let count = toolButtons.count
        for (index, button) in toolButtons.enumerated() {
            let angle = CGFloat(164) + CGFloat(index) * 150 / CGFloat(max(1, count - 1))
            button.frame = centeredFrame(point(radius: radius, degrees: angle))
        }
        for (offset, angle) in ([201.0, 216.0, 232.0, 247.0] as [CGFloat]).enumerated() {
            colorButtons[offset].frame = centeredFrame(point(radius: colorRadius, degrees: angle))
        }
    }
}
