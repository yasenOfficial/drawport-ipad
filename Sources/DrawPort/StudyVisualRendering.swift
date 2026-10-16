import UIKit

/// All v1 study assets are drawn locally from validated, bounded data.
/// No model-authored SVG/HTML/script is interpreted by UIKit or WebKit.
private final class StudyVisualCanvas: UIView {
    var asset: StudyVisualAsset { didSet { setNeedsDisplay() } }
    private var azimuth = Double.pi / 5
    private var elevation = Double.pi / 6
    init(asset: StudyVisualAsset) {
        self.asset = asset
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(rotate(_:)))
        addGestureRecognizer(gesture)
        isAccessibilityElement = true
        accessibilityLabel = "Offline \(asset.kind.rawValue): \(asset.caption)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func rotate(_ gesture: UIPanGestureRecognizer) {
        guard asset.kind == .surface3D || asset.kind == .vectors3D else { return }
        let delta = gesture.translation(in: self)
        azimuth += Double(delta.x) * 0.008
        elevation = min(1.3, max(-1.3, elevation + Double(delta.y) * 0.008))
        gesture.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }
    private func ink(_ color: StudyVisualVector.Color) -> UIColor {
        switch color {
        case .blue: UIColor(red: 0.1, green: 0.33, blue: 0.8, alpha: 1)
        case .red: UIColor(red: 0.77, green: 0.17, blue: 0.2, alpha: 1)
        case .green: UIColor(red: 0.11, green: 0.47, blue: 0.25, alpha: 1)
        case .purple: UIColor(red: 0.48, green: 0.22, blue: 0.65, alpha: 1)
        case .black: .black
        case .orange: UIColor(red: 0.8, green: 0.34, blue: 0.08, alpha: 1)
        }
    }
    private func line(_ a: CGPoint, _ b: CGPoint, color: UIColor, width: CGFloat = 1) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
    }
    private func text(_ value: String, at point: CGPoint, color: UIColor = .darkGray, size: CGFloat = 12) {
        (value as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: size),
                                                             .foregroundColor: color])
    }
    override func draw(_ rect: CGRect) {
        let area = bounds.insetBy(dx: 22, dy: 20)
        guard area.width > 20, area.height > 20, let context = UIGraphicsGetCurrentContext() else { return }
        switch asset.kind {
        case .function2D:
            guard let plot = asset.plot else { return }
            let parameters = Dictionary(uniqueKeysWithValues: (asset.parameters ?? []).map { ($0.name, $0.value) })
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: area.minX + CGFloat((x - plot.xMin) / (plot.xMax - plot.xMin)) * area.width,
                        y: area.maxY - CGFloat((y - plot.yMin) / (plot.yMax - plot.yMin)) * area.height)
            }
            if (plot.xMin...plot.xMax).contains(0) {
                let x = point(0, 0).x
                line(CGPoint(x: x, y: area.minY), CGPoint(x: x, y: area.maxY), color: .gray)
            }
            if (plot.yMin...plot.yMax).contains(0) {
                let y = point(0, 0).y
                line(CGPoint(x: area.minX, y: y), CGPoint(x: area.maxX, y: y), color: .gray)
            }
            text(String(format: "x [%.1f, %.1f]", plot.xMin, plot.xMax), at: CGPoint(x: area.minX, y: area.maxY - 3))
            context.saveGState()
            context.clip(to: area)
            context.setStrokeColor(ink(.blue).cgColor)
            context.setLineWidth(2.5)
            var started = false
            for i in 0...240 {
                let x = plot.xMin + (plot.xMax - plot.xMin) * Double(i) / 240
                guard let y = plot.evaluate(x: x, y: 0, parameters: parameters) else { started = false; continue }
                let p = point(x, y)
                if started { context.addLine(to: p) } else { context.move(to: p); started = true }
            }
            context.strokePath()
            context.restoreGState()
        case .vectors3D, .surface3D:
            let plot = asset.plot
            let vectors = asset.vectors ?? []
            let maxVector = vectors.flatMap { [abs($0.x), abs($0.y), abs($0.z)] }.max() ?? 1
            let domain = plot.map { max(abs($0.xMin), abs($0.xMax), abs($0.yMin), abs($0.yMax)) } ?? 1
            var maxZ = 0.0
            let parameters = Dictionary(uniqueKeysWithValues: (asset.parameters ?? []).map { ($0.name, $0.value) })
            if let plot {
                for i in 0...10 {
                    for j in 0...10 {
                        let x = plot.xMin + (plot.xMax - plot.xMin) * Double(i) / 10
                        let y = plot.yMin + (plot.yMax - plot.yMin) * Double(j) / 10
                        maxZ = max(maxZ, abs(plot.evaluate(x: x, y: y, parameters: parameters) ?? 0))
                    }
                }
            }
            let scale = max(1, maxVector, domain, maxZ)
            func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
                let horizontal = x * cos(azimuth) - y * sin(azimuth)
                let depth = x * sin(azimuth) + y * cos(azimuth)
                return CGPoint(x: area.midX + CGFloat(horizontal / scale) * area.width * 0.32,
                               y: area.midY + CGFloat((depth * sin(elevation) - z * cos(elevation)) / scale) * area.height * 0.35)
            }
            let origin = project(0, 0, 0)
            for (name, x, y, z, color) in [("x", 1.0, 0.0, 0.0, UIColor.systemRed),
                                            ("y", 0.0, 1.0, 0.0, UIColor.systemGreen),
                                            ("z", 0.0, 0.0, 1.0, UIColor.systemBlue)] {
                let end = project(x * scale, y * scale, z * scale)
                line(origin, end, color: color.withAlphaComponent(0.65), width: 1.4)
                text(name, at: end, color: color)
            }
            if let plot {
                for i in 0...20 {
                    for axis in 0...1 {
                        var previous: CGPoint?
                        for j in 0...20 {
                            let u = Double(i) / 20, v = Double(j) / 20
                            let x = plot.xMin + (plot.xMax - plot.xMin) * (axis == 0 ? u : v)
                            let y = plot.yMin + (plot.yMax - plot.yMin) * (axis == 0 ? v : u)
                            guard let z = plot.evaluate(x: x, y: y, parameters: parameters) else {
                                previous = nil
                                continue
                            }
                            let point = project(x, y, z)
                            if let previous { line(previous, point, color: ink(.blue).withAlphaComponent(0.52)) }
                            previous = point
                        }
                    }
                }
            }
            for vector in vectors {
                let end = project(vector.x, vector.y, vector.z)
                let color = ink(vector.color)
                line(origin, end, color: color, width: 3)
                let dx = end.x - origin.x, dy = end.y - origin.y
                let angle = atan2(dy, dx), length: CGFloat = 11
                line(end, CGPoint(x: end.x - length * cos(angle - 0.5),
                                  y: end.y - length * sin(angle - 0.5)), color: color, width: 3)
                line(end, CGPoint(x: end.x - length * cos(angle + 0.5),
                                  y: end.y - length * sin(angle + 0.5)), color: color, width: 3)
                text(String(format: "%@ (%.2f, %.2f, %.2f)", vector.label, vector.x, vector.y, vector.z),
                     at: CGPoint(x: end.x + 5, y: end.y - 18), color: color, size: 12)
            }
        case .diagram:
            for primitive in asset.primitives ?? [] {
                let color = ink(primitive.color)
                let coords = primitive.coordinates
                func point(_ index: Int) -> CGPoint {
                    CGPoint(x: area.minX + CGFloat(coords[index]) * area.width,
                            y: area.minY + CGFloat(coords[index + 1]) * area.height)
                }
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(CGFloat(primitive.thickness))
                switch primitive.kind {
                case .line:
                    line(point(0), point(2), color: color, width: CGFloat(primitive.thickness))
                case .rectangle, .ellipse:
                    let a = point(0), b = point(2)
                    let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                     width: abs(a.x - b.x), height: abs(a.y - b.y))
                    if primitive.kind == .rectangle { context.stroke(box) }
                    else { context.strokeEllipse(in: box) }
                case .polyline, .polygon:
                    context.move(to: point(0))
                    for i in stride(from: 2, to: coords.count, by: 2) { context.addLine(to: point(i)) }
                    if primitive.kind == .polygon { context.closePath() }
                    context.strokePath()
                case .text:
                    text(primitive.text ?? "", at: point(0), color: color, size: 16)
                }
            }
        case .table:
            guard let table = asset.table else { return }
            let rows = [table.columns] + table.rows
            let columnWidth = area.width / CGFloat(table.columns.count)
            let rowHeight = min(26, area.height / CGFloat(max(1, rows.count)))
            for (rowIndex, row) in rows.enumerated() {
                let y = area.minY + CGFloat(rowIndex) * rowHeight
                guard y + rowHeight <= area.maxY + 1 else { break }
                for (columnIndex, value) in row.enumerated() {
                    let x = area.minX + CGFloat(columnIndex) * columnWidth
                    let cell = CGRect(x: x, y: y, width: columnWidth, height: rowHeight)
                    context.setStrokeColor(UIColor.lightGray.cgColor)
                    context.stroke(cell)
                    (value as NSString).draw(in: cell.insetBy(dx: 3, dy: 4),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 12),
                                                              .foregroundColor: UIColor.black])
                }
            }
        }
    }
}

/// Native card for accepted proposals and offline examples. Other page touches
/// still pass through the existing StudyGraphOverlay to PencilKit.
final class StudyVisualCard: UIView {
    private(set) var asset: StudyVisualAsset
    var onCommit: ((StudyVisualAsset) -> Void)?
    var onRemove: ((UUID) -> Void)?
    private let pageSize: CGSize
    private let canvas: StudyVisualCanvas
    init(asset: StudyVisualAsset, pageSize: CGSize) {
        self.asset = asset
        self.pageSize = pageSize
        canvas = StudyVisualCanvas(asset: asset)
        let width = CGFloat(asset.width), height = CGFloat(asset.height)
        super.init(frame: CGRect(x: CGFloat(asset.x) * max(0, pageSize.width - width),
                                 y: CGFloat(asset.y) * max(0, pageSize.height - height),
                                 width: width, height: height))
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        layer.cornerRadius = 13
        layer.borderColor = UIColor(white: 0.72, alpha: 1).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 8
        accessibilityIdentifier = "studyVisual.\(asset.id.uuidString)"
        let title = UILabel()
        title.text = asset.caption
        title.textColor = .black
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragCard(_:))))
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        remove.accessibilityLabel = "Remove visual"
        remove.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onRemove?(self.asset.id)
        }, for: .touchUpInside)
        remove.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let header = UIStackView(arrangedSubviews: [title, remove])
        header.axis = .horizontal
        header.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let stack = UIStackView(arrangedSubviews: [header, canvas])
        stack.axis = .vertical
        stack.spacing = 5
        for (index, parameter) in (asset.parameters ?? []).enumerated() {
            let slider = UISlider()
            slider.minimumValue = Float(parameter.min)
            slider.maximumValue = Float(parameter.max)
            slider.value = Float(parameter.value)
            slider.accessibilityLabel = "Parameter \(parameter.name) \(parameter.unit)"
            let value = UILabel()
            value.textColor = .darkGray
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            value.text = String(format: "%@ = %.2f %@", parameter.name, parameter.value, parameter.unit)
            value.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let row = UIStackView(arrangedSubviews: [slider, value])
            row.axis = .horizontal
            row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            stack.addArrangedSubview(row)
            slider.addAction(UIAction { [weak self, weak value, weak slider] _ in
                guard let self, let slider, self.asset.parameters?.indices.contains(index) == true else { return }
                let item = self.asset.parameters![index]
                let stepped = (Double(slider.value) / item.step).rounded() * item.step
                let bounded = min(item.max, max(item.min, stepped))
                self.asset.parameters![index].value = bounded
                value?.text = String(format: "%@ = %.2f %@", item.name, bounded, item.unit)
                self.canvas.asset = self.asset
            }, for: .valueChanged)
            slider.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onCommit?(self.asset)
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func dragCard(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: superview)
        if gesture.state == .changed {
            frame.origin.x = min(max(0, frame.minX + delta.x), max(0, pageSize.width - bounds.width))
            frame.origin.y = min(max(0, frame.minY + delta.y), max(0, pageSize.height - bounds.height))
            gesture.setTranslation(.zero, in: superview)
        } else if gesture.state == .ended {
            asset.x = Double(frame.minX / max(1, pageSize.width - bounds.width))
            asset.y = Double(frame.minY / max(1, pageSize.height - bounds.height))
            onCommit?(asset)
        }
    }
}
