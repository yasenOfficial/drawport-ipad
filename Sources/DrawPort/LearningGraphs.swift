import Foundation
import UIKit

/// Declarative, locally calculated study objects. No model-generated script or
/// remote web content is executed on a notebook page.
struct StudyGraph: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case quadratic, sine, linear

        var title: String {
            switch self {
            case .quadratic: "y = a·x²"
            case .sine: "y = a·sin(x)"
            case .linear: "y = a·x"
            }
        }
        func value(x: Double, a: Double) -> Double {
            switch self {
            case .quadratic: a * x * x
            case .sine: a * sin(x)
            case .linear: a * x
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var parameter: Double = 0.5
    var x: Double
    var y: Double

    func validate() throws {
        guard parameter.isFinite, (-4...4).contains(parameter), x.isFinite, y.isFinite,
              (0...4000).contains(x), (0...4000).contains(y) else { throw StudyGraphError.invalidData }
    }
}

enum StudyGraphError: LocalizedError {
    case invalidData
    var errorDescription: String? { "The saved interactive graph could not be validated; it was not changed." }
}

/// Separate, versioned sidecars avoid rewriting legacy PencilKit history and
/// keep old notebook data untouched. A corrupt sidecar is never overwritten.
final class StudyGraphStore {
    private struct Document: Codable {
        var version: Int
        var notebook: UUID
        var page: UUID
        var graphs: [StudyGraph]
    }

    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("InteractiveGraphs", isDirectory: true) }

    private func path(book: UUID, page: UUID) -> URL {
        root.appendingPathComponent(book.uuidString, isDirectory: true)
            .appendingPathComponent(page.uuidString + ".json")
    }

    func load(book: UUID, page: UUID) throws -> [StudyGraph] {
        let file = path(book: book, page: page)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count < 200_000 else { throw StudyGraphError.invalidData }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.notebook == book, document.page == page,
              document.graphs.count <= 16,
              Set(document.graphs.map(\.id)).count == document.graphs.count else { throw StudyGraphError.invalidData }
        try document.graphs.forEach { try $0.validate() }
        return document.graphs
    }

    func save(_ graphs: [StudyGraph], book: UUID, page: UUID) throws {
        guard graphs.count <= 16, Set(graphs.map(\.id)).count == graphs.count else { throw StudyGraphError.invalidData }
        try graphs.forEach { try $0.validate() }
        // Do not replace a corrupt file: preserve it for diagnosis/recovery.
        _ = try load(book: book, page: page)
        let file = path(book: book, page: page)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(Document(version: 1, notebook: book, page: page, graphs: graphs))
        try bytes.write(to: file, options: .atomic)
    }
}

private final class StudyGraphPlot: UIView {
    var graph: StudyGraph? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        isOpaque = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let graph, let context = UIGraphicsGetCurrentContext() else { return }
        let area = bounds.insetBy(dx: 18, dy: 11)
        guard area.width > 10, area.height > 10 else { return }
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: area.midX + CGFloat(x) * area.width / 10,
                    y: area.midY - CGFloat(y) * area.height / 16)
        }
        context.setLineWidth(0.7)
        context.setStrokeColor(UIColor(white: 0.84, alpha: 1).cgColor)
        for i in -5...5 {
            let x = point(Double(i), 0).x
            context.move(to: CGPoint(x: x, y: area.minY))
            context.addLine(to: CGPoint(x: x, y: area.maxY))
        }
        for i in -8...8 where i.isMultiple(of: 2) {
            let y = point(0, Double(i)).y
            context.move(to: CGPoint(x: area.minX, y: y))
            context.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        context.strokePath()
        context.setLineWidth(1.4)
        context.setStrokeColor(UIColor(white: 0.4, alpha: 1).cgColor)
        context.move(to: CGPoint(x: area.minX, y: area.midY))
        context.addLine(to: CGPoint(x: area.maxX, y: area.midY))
        context.move(to: CGPoint(x: area.midX, y: area.minY))
        context.addLine(to: CGPoint(x: area.midX, y: area.maxY))
        context.strokePath()
        context.saveGState()
        context.clip(to: area)
        context.setStrokeColor(UIColor(red: 0.09, green: 0.36, blue: 0.81, alpha: 1).cgColor)
        context.setLineWidth(2.7)
        context.setLineJoin(.round)
        let steps = max(50, Int(area.width * 1.5))
        for step in 0...steps {
            let x = -5 + Double(step) * 10 / Double(steps)
            let y = graph.kind.value(x: x, a: graph.parameter)
            let p = point(x, y)
            if step == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
        context.strokePath()
        context.restoreGState()
    }
}

final class StudyGraphCard: UIView {
    static let cardSize = CGSize(width: 500, height: 400)
    private(set) var graph: StudyGraph
    var onCommit: ((StudyGraph) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onExport: ((StudyGraph) -> Void)?
    private let plot = StudyGraphPlot()
    private let title = UILabel()
    private let value = UILabel()
    private let table = UILabel()
    private let slider = UISlider()

    init(graph: StudyGraph) {
        self.graph = graph
        super.init(frame: CGRect(origin: CGPoint(x: graph.x, y: graph.y), size: Self.cardSize))
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        layer.cornerRadius = 13
        layer.borderColor = UIColor(white: 0.76, alpha: 1).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.17
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        accessibilityIdentifier = "interactiveGraph.\(graph.id.uuidString)"

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .black
        title.text = graph.kind.title
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveGraph(_:))))
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        remove.accessibilityLabel = "Remove graph"
        remove.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onRemove?(self.graph.id)
        }, for: .touchUpInside)
        let export = UIButton(type: .system)
        export.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        export.accessibilityLabel = "Export interactive graph"
        export.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onExport?(self.graph)
        }, for: .touchUpInside)
        plot.graph = graph
        value.textColor = .darkGray
        value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        slider.minimumValue = -2
        slider.maximumValue = 2
        slider.value = Float(graph.parameter)
        slider.accessibilityLabel = "Graph parameter a"
        slider.addAction(UIAction { [weak self] _ in self?.changeParameter() }, for: .valueChanged)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            slider.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onCommit?(self.graph)
            }, for: event)
        }
        let tableButton = UIButton(type: .system)
        tableButton.setImage(UIImage(systemName: "tablecells"), for: .normal)
        tableButton.accessibilityLabel = "Toggle graph values table"
        tableButton.addAction(UIAction { [weak self] _ in self?.toggleTable() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, tableButton, export, remove])
        header.axis = .horizontal
        header.spacing = 8
        for control in [tableButton, export, remove] {
            control.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        table.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        table.textAlignment = .center
        table.textColor = .black
        table.numberOfLines = 0
        table.isHidden = true
        let plotContainer = UIView()
        for child in [plot, table] {
            plotContainer.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: plotContainer.topAnchor),
                child.bottomAnchor.constraint(equalTo: plotContainer.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: plotContainer.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: plotContainer.trailingAnchor)
            ])
        }
        let parameterRow = UIStackView(arrangedSubviews: [slider, value])
        parameterRow.axis = .horizontal
        parameterRow.alignment = .center
        parameterRow.spacing = 10
        value.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let stack = UIStackView(arrangedSubviews: [header, plotContainer, parameterRow])
        stack.axis = .vertical
        stack.spacing = 4
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 32),
            parameterRow.heightAnchor.constraint(equalToConstant: 32)
        ])
        updateValues()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateValues() {
        value.text = String(format: "a = %.2f", graph.parameter)
        let rows = (-3...3).map { x in String(format: "%3d  │  %7.2f", x,
            graph.kind.value(x: Double(x), a: graph.parameter)) }
        table.text = "  x  │      y\n" + rows.joined(separator: "\n")
    }
    private func changeParameter() {
        graph.parameter = (Double(slider.value) * 20).rounded() / 20
        updateValues()
        plot.graph = graph
    }
    private func toggleTable() {
        table.isHidden.toggle()
        plot.isHidden = !table.isHidden
    }
    @objc private func moveGraph(_ recognizer: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        let delta = recognizer.translation(in: parent)
        if recognizer.state == .changed {
            frame.origin.x = min(max(0, frame.minX + delta.x), max(0, parent.bounds.width - bounds.width))
            frame.origin.y = min(max(0, frame.minY + delta.y), max(0, parent.bounds.height - bounds.height))
            recognizer.setTranslation(.zero, in: parent)
        } else if recognizer.state == .ended {
            graph.x = Double(frame.minX)
            graph.y = Double(frame.minY)
            onCommit?(graph)
        }
    }
}

/// Only graph cards accept touches; PencilKit keeps the rest of the page.
final class StudyGraphOverlay: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        for card in subviews.reversed() where card.frame.contains(point) {
            let local = convert(point, to: card)
            return card.hitTest(local, with: event)
        }
        return nil
    }
}

/// A self-contained offline HTML export. PDF/image exports can rasterize this
/// graph; unlike PDF, this HTML retains its slider without a network or API key.
enum StudyGraphHTML {
    static func document(_ graph: StudyGraph) -> String {
        let kind = graph.kind.rawValue // Only compiler-defined enum values enter JS.
        let a = String(graph.parameter) // Locale-independent HTML number.
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Interactive study graph</title><style>body{font:16px system-ui;max-width:800px;margin:32px auto;padding:16px;color:#202020;background:#fffeee}canvas{width:100%;border:1px solid #bbb;background:#fff}input{width:100%}</style>
        <h1>\(graph.kind.title)</h1><canvas id="plot" width="760" height="420"></canvas>
        <label for="a">Parameter a: <output id="value"></output></label><input id="a" type="range" min="-2" max="2" step="0.05" value="\(a)">
        <script>(function(){'use strict';const c=document.getElementById('plot'),g=c.getContext('2d'),s=document.getElementById('a'),v=document.getElementById('value');
        const kind='\(kind)';function f(x,a){return kind==='quadratic'?a*x*x:kind==='sine'?a*Math.sin(x):a*x}
        function draw(){let a=Number(s.value);v.textContent=a.toFixed(2);g.clearRect(0,0,c.width,c.height);g.strokeStyle='#dedede';g.lineWidth=1;
        for(let i=-5;i<=5;i++){let p=(i+5)*c.width/10;g.beginPath();g.moveTo(p,0);g.lineTo(p,c.height);g.stroke()}
        for(let i=-8;i<=8;i+=2){let p=(8-i)*c.height/16;g.beginPath();g.moveTo(0,p);g.lineTo(c.width,p);g.stroke()}
        g.strokeStyle='#555';g.beginPath();g.moveTo(c.width/2,0);g.lineTo(c.width/2,c.height);g.moveTo(0,c.height/2);g.lineTo(c.width,c.height/2);g.stroke();
        g.save();g.beginPath();g.rect(0,0,c.width,c.height);g.clip();g.strokeStyle='#175ccf';g.lineWidth=3;g.beginPath();
        for(let p=0;p<=c.width;p+=2){let x=p*10/c.width-5,y=(8-f(x,a))*c.height/16;if(p===0)g.moveTo(p,y);else g.lineTo(p,y)}g.stroke();g.restore()}
        s.addEventListener('input',draw);draw()})();</script></html>
        """
    }
}
