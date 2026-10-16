import Foundation

// DrawPort visual-proposal wire format v1. No raw SVG/HTML, JavaScript, URLs,
// shaders, custom fonts, or model-authored expressions are ever executed.
// A proposal is inert until the client validates it and the student accepts it.
enum StudyVisualProtocolError: Error { case invalid }

struct StudyVisualProposal: Codable {
    var version: Int
    var requestID: UUID
    var contextHash: String // Lowercase SHA-256 of the consented question/context.
    var explanation: String
    var assets: [StudyVisualAsset]

    static func parse(_ data: Data, requestID: UUID, contextHash: String,
                      availableSources: Set<UUID>) throws -> Self {
        guard data.count <= 48_000, contextHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudyVisualProtocolError.invalid
        }
        try keys(object, ["version", "requestID", "contextHash", "explanation", "assets"])
        guard let rawAssets = object["assets"] as? [[String: Any]], rawAssets.count <= 2 else {
            throw StudyVisualProtocolError.invalid
        }
        for asset in rawAssets {
            try keys(asset, ["id", "kind", "caption", "trigger", "width", "height", "x", "y",
                             "sourceIDs", "parameters", "plot", "vectors", "primitives", "table"])
            for (name, allowed) in [("parameters", ["name", "value", "min", "max", "step", "unit"]),
                                    ("vectors", ["label", "x", "y", "z", "color"]),
                                    ("primitives", ["kind", "coordinates", "text", "color", "thickness"])] {
                if let entries = asset[name] as? [[String: Any]] {
                    for entry in entries { try keys(entry, Set(allowed)) }
                }
            }
            if let plot = asset["plot"] as? [String: Any] {
                try keys(plot, ["xMin", "xMax", "yMin", "yMax", "nodes", "output"])
                if let nodes = plot["nodes"] as? [[String: Any]] {
                    for node in nodes { try keys(node, ["op", "inputs", "literal", "parameter", "exponent"]) }
                }
            }
            if let table = asset["table"] as? [String: Any] { try keys(table, ["columns", "rows"]) }
        }
        let proposal = try JSONDecoder().decode(Self.self, from: data)
        guard proposal.version == 1, proposal.requestID == requestID,
              proposal.contextHash == contextHash, proposal.explanation.count <= 5_000,
              !proposal.explanation.unicodeScalars.contains(where: { $0.value == 0 }),
              proposal.assets.map(\.id).count == Set(proposal.assets.map(\.id)).count else {
            throw StudyVisualProtocolError.invalid
        }
        for asset in proposal.assets { try asset.validate(availableSources: availableSources) }
        return proposal
    }

    private static func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw StudyVisualProtocolError.invalid }
    }
}

struct StudyVisualAsset: Codable {
    enum Kind: String, Codable { case function2D, surface3D, vectors3D, diagram, table }
    enum Trigger: String, Codable { case requested, naturallyUseful }
    var id: UUID
    var kind: Kind
    var caption: String
    var trigger: Trigger
    var width: Double
    var height: Double
    var x: Double // Normalized hint; final page placement is always client-controlled.
    var y: Double
    var sourceIDs: [UUID]
    var parameters: [StudyVisualParameter]?
    var plot: StudyVisualPlot?
    var vectors: [StudyVisualVector]?
    var primitives: [StudyVisualPrimitive]?
    var table: StudyVisualTable?

    func validate(availableSources: Set<UUID>) throws {
        guard caption.count <= 200, !caption.isEmpty,
              (200...700).contains(width), (140...550).contains(height),
              (0...1).contains(x), (0...1).contains(y),
              sourceIDs.count <= 4, Set(sourceIDs).count == sourceIDs.count,
              Set(sourceIDs).isSubset(of: availableSources) else { throw StudyVisualProtocolError.invalid }
        // Closed enums, closed payload shape. Optional does NOT mean arbitrary
        // extra fields are permitted on a different kind.
        let params = parameters ?? []
        guard params.count <= 3, Set(params.map(\.name)).count == params.count else {
            throw StudyVisualProtocolError.invalid
        }
        for parameter in params { try parameter.validate() }
        switch kind {
        case .function2D, .surface3D:
            guard let plot, vectors == nil, primitives == nil, table == nil else { throw StudyVisualProtocolError.invalid }
            try plot.validate(parameters: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value) }),
                              threeD: kind == .surface3D)
        case .vectors3D:
            guard plot == nil, primitives == nil, table == nil, params.isEmpty,
                  let vectors, (1...12).contains(vectors.count) else { throw StudyVisualProtocolError.invalid }
            for vector in vectors { try vector.validate() }
        case .diagram:
            guard plot == nil, vectors == nil, table == nil, params.isEmpty,
                  let primitives, (1...80).contains(primitives.count) else { throw StudyVisualProtocolError.invalid }
            for primitive in primitives { try primitive.validate() }
        case .table:
            guard plot == nil, vectors == nil, primitives == nil, params.isEmpty, let table else {
                throw StudyVisualProtocolError.invalid
            }
            try table.validate()
        }
    }
}

struct StudyVisualParameter: Codable {
    var name: String
    var value: Double
    var min: Double
    var max: Double
    var step: Double
    var unit: String
    func validate() throws {
        guard ["a", "b", "c"].contains(name), [value, min, max, step].allSatisfy(\.isFinite),
              min >= -100, max <= 100, min < max, (min...max).contains(value),
              step >= 0.01, step <= max - min,
              ["", "m", "s", "kg", "rad", "°", "%"].contains(unit) else {
            throw StudyVisualProtocolError.invalid
        }
    }
}

// Topologically ordered bounded expression DAG. No arbitrary parser/eval.
// `x` and `y` represent the local coordinates, not files or external data.
struct StudyVisualNode: Codable {
    enum Op: String, Codable { case constant, x, y, parameter, add, subtract, multiply, divide, sin, cos, power }
    var op: Op
    var inputs: [Int]
    var literal: Double?
    var parameter: String?
    var exponent: Int?

    func validate(at index: Int, parameterNames: Set<String>, threeD: Bool) throws {
        guard inputs.allSatisfy({ $0 >= 0 && $0 < index }) else { throw StudyVisualProtocolError.invalid }
        let literalOK = literal == nil || (literal!.isFinite && abs(literal!) <= 1_000)
        guard literalOK else { throw StudyVisualProtocolError.invalid }
        switch op {
        case .constant:
            guard inputs.isEmpty, literal != nil, parameter == nil, exponent == nil else { throw StudyVisualProtocolError.invalid }
        case .x, .y:
            guard (op != .y || threeD), inputs.isEmpty, literal == nil,
                  parameter == nil, exponent == nil else { throw StudyVisualProtocolError.invalid }
        case .parameter:
            guard inputs.isEmpty, literal == nil, exponent == nil,
                  let parameter, parameterNames.contains(parameter) else { throw StudyVisualProtocolError.invalid }
        case .add, .subtract, .multiply, .divide:
            guard inputs.count == 2, literal == nil, parameter == nil, exponent == nil else { throw StudyVisualProtocolError.invalid }
        case .sin, .cos:
            guard inputs.count == 1, literal == nil, parameter == nil, exponent == nil else { throw StudyVisualProtocolError.invalid }
        case .power:
            guard inputs.count == 1, literal == nil, parameter == nil,
                  let exponent, (0...4).contains(exponent) else { throw StudyVisualProtocolError.invalid }
        }
    }
}

struct StudyVisualPlot: Codable {
    var xMin: Double
    var xMax: Double
    var yMin: Double
    var yMax: Double
    var nodes: [StudyVisualNode]
    var output: Int

    func validate(parameters: [String: Double], threeD: Bool) throws {
        guard [xMin, xMax, yMin, yMax].allSatisfy(\.isFinite),
              xMin >= -100, xMax <= 100, yMin >= -100, yMax <= 100,
              xMax - xMin >= 0.1, yMax - yMin >= 0.1,
              (1...48).contains(nodes.count), output == nodes.count - 1 else {
            throw StudyVisualProtocolError.invalid
        }
        for (i, node) in nodes.enumerated() { try node.validate(at: i, parameterNames: Set(parameters.keys), threeD: threeD) }
        // Reject singularities/overflow over a bounded preview sample before UI.
        let samples = threeD ? 12 : 64
        for i in 0...samples {
            let x = xMin + (xMax - xMin) * Double(i) / Double(samples)
            for j in 0...(threeD ? samples : 0) {
                let y = threeD ? yMin + (yMax - yMin) * Double(j) / Double(samples) : 0
                guard evaluate(x: x, y: y, parameters: parameters) != nil else { throw StudyVisualProtocolError.invalid }
            }
        }
    }

    func evaluate(x: Double, y: Double, parameters: [String: Double]) -> Double? {
        var values = [Double]()
        for node in nodes {
            let a = node.inputs.first.map { values[$0] } ?? 0
            let b = node.inputs.count > 1 ? values[node.inputs[1]] : 0
            let result: Double
            switch node.op {
            case .constant: result = node.literal ?? 0
            case .x: result = x
            case .y: result = y
            case .parameter: result = parameters[node.parameter ?? ""] ?? 0
            case .add: result = a + b
            case .subtract: result = a - b
            case .multiply: result = a * b
            case .divide: guard abs(b) >= 1e-9 else { return nil }; result = a / b
            case .sin: result = sin(a)
            case .cos: result = cos(a)
            case .power: result = pow(a, Double(node.exponent ?? 0))
            }
            guard result.isFinite, abs(result) <= 1e12 else { return nil }
            values.append(result)
        }
        return values.indices.contains(output) ? values[output] : nil
    }
}

struct StudyVisualVector: Codable {
    enum Color: String, Codable { case blue, red, green, purple, black, orange }
    var label: String
    var x: Double
    var y: Double
    var z: Double
    var color: Color
    func validate() throws {
        guard !label.isEmpty, label.count <= 24,
              [x, y, z].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else {
            throw StudyVisualProtocolError.invalid
        }
    }
}

// Whitelisted declarative SVG-like primitives; coordinates are normalized and
// rendered by the app, never parsed as SVG markup. No paths/URLs/styles/scripts.
struct StudyVisualPrimitive: Codable {
    enum Kind: String, Codable { case line, polyline, polygon, rectangle, ellipse, text }
    var kind: Kind
    var coordinates: [Double]
    var text: String?
    var color: StudyVisualVector.Color
    var thickness: Double
    func validate() throws {
        guard coordinates.count <= 128,
              coordinates.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              thickness.isFinite && (0.5...8).contains(thickness) else { throw StudyVisualProtocolError.invalid }
        switch kind {
        case .line, .rectangle, .ellipse:
            guard coordinates.count == 4, text == nil else { throw StudyVisualProtocolError.invalid }
        case .polyline, .polygon:
            guard coordinates.count >= (kind == .polygon ? 6 : 4), coordinates.count.isMultiple(of: 2),
                  text == nil else { throw StudyVisualProtocolError.invalid }
        case .text:
            guard coordinates.count == 2, let text, !text.isEmpty, text.count <= 120,
                  !text.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw StudyVisualProtocolError.invalid
            }
        }
    }
}

struct StudyVisualTable: Codable {
    var columns: [String]
    var rows: [[String]]
    func validate() throws {
        guard (1...8).contains(columns.count), rows.count <= 32,
              rows.allSatisfy({ $0.count == columns.count }),
              (columns + rows.flatMap { $0 }).allSatisfy({
                  $0.count <= 100 && !$0.unicodeScalars.contains(where: { $0.value < 32 })
              }) else { throw StudyVisualProtocolError.invalid }
    }
}
