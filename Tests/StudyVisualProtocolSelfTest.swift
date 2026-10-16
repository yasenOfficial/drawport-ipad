import Foundation

@main struct VisualProtocolSelfTest {
    static func main() throws {
        let request = UUID(), source = UUID(), context = String(repeating: "a", count: 64)
        func envelope(_ asset: [String: Any], version: Int = 1, hash: String? = nil) -> [String: Any] {
            ["version": version, "requestID": request.uuidString, "contextHash": hash ?? context,
             "explanation": "Test only", "assets": [asset]]
        }
        func parse(_ json: [String: Any], sources: Set<UUID> = []) throws -> StudyVisualProposal {
            let bytes = try JSONSerialization.data(withJSONObject: json)
            return try StudyVisualProposal.parse(bytes, requestID: request,
                                                 contextHash: context, availableSources: sources)
        }
        func rejected(_ json: [String: Any], sources: Set<UUID> = []) throws {
            do { _ = try parse(json, sources: sources); fatalError("Invalid proposal accepted") }
            catch StudyVisualProtocolError.invalid { }
            catch DecodingError.typeMismatch { }
            catch DecodingError.valueNotFound { }
            catch DecodingError.keyNotFound { }
            catch DecodingError.dataCorrupted { }
        }
        var vectors: [String: Any] = [
            "id": UUID().uuidString, "kind": "vectors3D", "caption": "Vector a", "trigger": "requested",
            "width": 450.0, "height": 320.0, "x": 0.1, "y": 0.2, "sourceIDs": [source.uuidString],
            "vectors": [["label": "a", "x": 1.0, "y": -2.0, "z": 3.0, "color": "purple"]]
        ]
        let validVectors = try parse(envelope(vectors), sources: [source])
        assert(validVectors.assets.count == 1)
        try rejected(envelope(vectors)) // Unknown/unconsented citation.
        try rejected(envelope(vectors, version: 2), sources: [source])
        try rejected(envelope(vectors, hash: String(repeating: "b", count: 64)), sources: [source])
        vectors["kind"] = "executeJS"; try rejected(envelope(vectors), sources: [source]); vectors["kind"] = "vectors3D"
        vectors["script"] = "alert(1)"; try rejected(envelope(vectors), sources: [source]); vectors.removeValue(forKey: "script")
        vectors["vectors"] = [["label": "a", "x": 1.0, "y": 2.0, "z": 3.0, "color": "url(file:///secret)"]]
        try rejected(envelope(vectors), sources: [source])
        vectors["vectors"] = [["label": "a", "x": 1.0, "y": 2.0, "z": 3.0, "color": "purple"]]
        vectors["width"] = 9_999.0; try rejected(envelope(vectors), sources: [source]); vectors["width"] = 450.0
        var plot: [String: Any] = ["id": UUID().uuidString, "kind": "function2D", "caption": "y = a·x²",
                                   "trigger": "naturallyUseful", "width": 500.0, "height": 300.0,
                                   "x": 0.15, "y": 0.2, "sourceIDs": [],
                                   "parameters": [["name": "a", "value": 2.0, "min": -3.0,
                                                   "max": 3.0, "step": 0.1, "unit": ""]],
                                   "plot": ["xMin": -4.0, "xMax": 4.0, "yMin": -8.0, "yMax": 8.0,
                                            "nodes": [["op": "parameter", "inputs": [], "parameter": "a"],
                                                      ["op": "x", "inputs": []],
                                                      ["op": "power", "inputs": [1], "exponent": 2],
                                                      ["op": "multiply", "inputs": [0, 2]]], "output": 3]]
        let function = try parse(envelope(plot)).assets[0]
        assert(function.plot?.evaluate(x: 3, y: 0, parameters: ["a": 2]) == 18)
        var damaged = plot["plot"] as! [String: Any]
        var nodes = damaged["nodes"] as! [[String: Any]]
        nodes[3]["inputs"] = [3, 2] // Cycle not topological.
        damaged["nodes"] = nodes; plot["plot"] = damaged
        try rejected(envelope(plot))
        nodes[3]["inputs"] = [0, 2]; damaged["nodes"] = nodes
        damaged["unknownParser"] = "eval()"; plot["plot"] = damaged
        try rejected(envelope(plot))
        damaged.removeValue(forKey: "unknownParser")
        damaged["nodes"] = nodes; plot["plot"] = damaged
        let validPlot = try parse(envelope(plot))
        assert(validPlot.assets.count == 1)
        var diagram: [String: Any] = ["id": UUID().uuidString, "kind": "diagram", "caption": "Triangle",
                                      "trigger": "requested", "width": 400.0, "height": 200.0,
                                      "x": 0.1, "y": 0.1, "sourceIDs": [],
                                      "primitives": [["kind": "polygon", "coordinates": [0.1, 0.1, 0.8, 0.1, 0.5, 0.8],
                                                      "color": "blue", "thickness": 2.0]]]
        let validDiagram = try parse(envelope(diagram))
        assert(validDiagram.assets.count == 1)
        diagram["primitives"] = [["kind": "text", "coordinates": [0.2, 0.2],
                                  "text": "bad\u{0000}", "color": "blue", "thickness": 2.0]]
        try rejected(envelope(diagram))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawPortVisualTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = UUID(), page = UUID()
        let store = StudyVisualStore(root: root)
        try store.save(validVectors.assets, book: book, page: page, availableSources: [source])
        let loaded = try store.load(book: book, page: page, availableSources: [source])
        assert(loaded.count == 1)
        let sidecar = root.appendingPathComponent("InteractiveVisuals/\(book.uuidString)/\(page.uuidString).json")
        let broken = Data("corrupt-but-retain".utf8)
        try broken.write(to: sidecar, options: .atomic)
        do {
            try store.save(validVectors.assets, book: book, page: page, availableSources: [source])
            fatalError("Corrupt sidecar was overwritten")
        } catch {
            let retained = try Data(contentsOf: sidecar)
            assert(retained == broken)
        }
        print("StudyVisualProtocol v1: valid 2D/vector/diagram + 10 invalid cases; atomic sidecar preservation passed")
    }
}
