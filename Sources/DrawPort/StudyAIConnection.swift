import CryptoKit
import Foundation
import PencilKit
import UIKit
import Vision

/// Only a private signing stage injects a tailnet HTTPS URL. The OpenRouter
/// credential never enters the IPA or this source repository.
enum StudyAIConfiguration {
    static var endpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DrawPortStudyAIURL") as? String,
              let url = URL(string: raw), url.scheme == "https",
              let host = url.host, host.hasSuffix(".ts.net"),
              url.port == nil, url.user == nil, url.password == nil,
              url.path == "/v1/study/ask", url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

private struct StudyQuestion: Encodable {
    let version = 1
    let question: String?
    let image: String? // Only the explicitly circled, bounded PNG crop.
}
private struct StudyStreamEvent: Decodable { let delta: String?; let error: String?; let done: Bool? }

enum StudyAIError: LocalizedError {
    case noPurpleInk, noContent, tooMuchInk, unreadable, server
    var errorDescription: String? {
        switch self {
        case .noPurpleInk: "Circle the context with purple ink, or write a question in purple. No data was sent."
        case .noContent: "The latest purple circle contains no ink strokes. Nothing was sent."
        case .tooMuchInk: "The purple area is too large to read safely. No data was sent."
        case .unreadable: "The iPad could not read the purple handwriting. No data was sent. Try writing it more clearly in purple."
        case .server: "Study AI is unavailable. The notebook was not changed."
        }
    }
}

struct StudyPurpleContext {
    let recognizedText: String? // Purple writing without an enclosure: local OCR.
    let imagePNG: Data?        // Enclosed page ink: only the interior crop.
    let sourceHash: String
    let bounds: CGRect
    let purpleStrokeIndices: [Int] // Only these marks disappear after Keep.
}

/// A closed purple loop selects strokes by the actual polygon, NOT the whole
/// bounding rectangle or page. The newest loop wins. No other ink is selected
/// if it crosses the loop boundary; the student previews the exact image.
private enum StudyInkEnclosure {
    struct Loop { let index: Int; let vertices: [CGPoint]; let bounds: CGRect }
    static func find(in drawing: PKDrawing) -> Loop? {
        for (index, stroke) in drawing.strokes.enumerated().reversed() where QuestionInk.matches(stroke.ink.color) {
            let path = stroke.path
            guard (12...10_000).contains(path.count) else { continue }
            let strideLength = max(1, path.count / 180)
            var vertices = Swift.stride(from: 0, to: path.count, by: strideLength)
                .map { path[$0].location.applying(stroke.transform) }
            vertices.append(path[path.count - 1].location.applying(stroke.transform))
            guard vertices.count >= 10,
                  vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let rect = stroke.renderBounds
            let diagonal = hypot(rect.width, rect.height)
            guard rect.width >= 45, rect.height >= 35, rect.width * rect.height <= 2_000_000,
                  diagonal.isFinite, diagonal > 60 else { continue }
            let travel = zip(vertices, vertices.dropFirst()).reduce(CGFloat.zero) {
                $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y)
            }
            let endGap = hypot(vertices[0].x - vertices[vertices.count - 1].x,
                               vertices[0].y - vertices[vertices.count - 1].y)
            guard endGap <= max(20, diagonal * 0.14), travel >= diagonal * 1.9 else { continue }
            let area = abs(zip(vertices, vertices.dropFirst() + [vertices[0]]).reduce(CGFloat.zero) {
                $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y)
            }) / 2
            guard area >= max(2_000, rect.width * rect.height * 0.23) else { continue }
            return Loop(index: index, vertices: vertices, bounds: rect)
        }
        return nil
    }
    static func contains(_ point: CGPoint, vertices: [CGPoint]) -> Bool {
        var inside = false
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    static func selectedIndices(from drawing: PKDrawing, inside loop: Loop) -> [Int] {
        drawing.strokes.enumerated().compactMap { index, stroke in
            guard index != loop.index, stroke.renderBounds.intersects(loop.bounds),
                  stroke.path.count > 0, stroke.path.count <= 10_000 else { return nil }
            let path = stroke.path
            let step = max(1, path.count / 90)
            let samples = Swift.stride(from: 0, to: path.count, by: step).map {
                path[$0].location.applying(stroke.transform)
            } + [path[path.count - 1].location.applying(stroke.transform)]
            guard samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite && contains($0, vertices: loop.vertices) }) else {
                return nil
            }
            return index
        }
    }
}

/// Purple *writing* is locally OCR'd into text. A purple *enclosure* instead
/// chooses the actual ink inside it (any ink color) and offers an image preview
/// on the page. Only that cropped image is sent after an explicit Send tap.
enum StudyPurpleCapture {
    @MainActor static func recognize(_ drawing: PKDrawing) async throws -> StudyPurpleContext {
        let purpleStrokes = drawing.strokes.filter { QuestionInk.matches($0.ink.color) }
        guard !purpleStrokes.isEmpty else { throw StudyAIError.noPurpleInk }
        guard drawing.strokes.count <= 3_000 else { throw StudyAIError.tooMuchInk }
        if let loop = StudyInkEnclosure.find(in: drawing) {
            let selectedIndices = StudyInkEnclosure.selectedIndices(from: drawing, inside: loop)
            guard !selectedIndices.isEmpty else { throw StudyAIError.noContent }
            guard selectedIndices.count <= 1_200 else { throw StudyAIError.tooMuchInk }
            let selected = selectedIndices.map { drawing.strokes[$0] }
            let crop = loop.bounds.insetBy(dx: -12, dy: -12).integral
            guard crop.width > 10, crop.height > 10,
                  crop.width <= 1_200, crop.height <= 1_200,
                  crop.width * crop.height <= 1_000_000 else { throw StudyAIError.tooMuchInk }
            let pixels = PKDrawing(strokes: selected)
            let format = UIGraphicsImageRendererFormat()
            format.scale = min(1.5, 1_024 / max(crop.width, crop.height))
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: crop.size, format: format).image { renderer in
                UIColor.white.setFill()
                renderer.cgContext.fill(CGRect(origin: .zero, size: crop.size))
                pixels.image(from: crop, scale: format.scale).draw(in: CGRect(origin: .zero, size: crop.size))
            }
            guard let png = image.pngData(), !png.isEmpty, png.count <= 180_000 else {
                throw StudyAIError.tooMuchInk
            }
            let position = String(format: "%.1f,%.1f,%.1f,%.1f", loop.bounds.minX, loop.bounds.minY,
                                  loop.bounds.width, loop.bounds.height)
            let hash = SHA256.hash(data: png + Data(position.utf8)).map { String(format: "%02x", $0) }.joined()
            let purpleIndices = [loop.index] + selectedIndices.filter {
                QuestionInk.matches(drawing.strokes[$0].ink.color)
            }
            return StudyPurpleContext(recognizedText: nil, imagePNG: png, sourceHash: hash,
                                      bounds: loop.bounds, purpleStrokeIndices: purpleIndices)
        }
        guard purpleStrokes.count <= 1_200 else { throw StudyAIError.tooMuchInk }
        let purple = PKDrawing(strokes: purpleStrokes)
        let raw = purple.bounds
        guard !raw.isNull, !raw.isEmpty,
              [raw.minX, raw.minY, raw.width, raw.height].allSatisfy(\.isFinite),
              raw.width <= 2_000, raw.height <= 2_000 else { throw StudyAIError.tooMuchInk }
        let region = raw.insetBy(dx: -16, dy: -16).integral
        guard region.width > 10, region.height > 10,
              region.width * region.height <= 2_000_000 else { throw StudyAIError.tooMuchInk }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: region.size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.cgContext.fill(CGRect(origin: .zero, size: region.size))
            purple.image(from: region, scale: 2).draw(in: CGRect(origin: .zero, size: region.size))
        }
        guard let cgImage = image.cgImage, let png = image.pngData(), png.count <= 5_000_000 else {
            throw StudyAIError.tooMuchInk
        }
        let sourceHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let text = try await Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
            request.recognitionLanguages = supported.contains("bg-BG") ? ["bg-BG", "en-US"] : ["en-US"]
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let observations = (request.results ?? []).sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return observations.prefix(40).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        guard text.count >= 2, text.count <= 700 else { throw StudyAIError.unreadable }
        let indices = drawing.strokes.indices.filter { QuestionInk.matches(drawing.strokes[$0].ink.color) }
        return StudyPurpleContext(recognizedText: text, imagePNG: nil, sourceHash: sourceHash,
                                  bounds: raw, purpleStrokeIndices: indices)
    }
}

/// Bounded stream: plain OCR text OR the exact cropped PNG from an explicit
/// purple enclosure. Never a full page, notebook, PDF or automatic graph.
enum StudyAIStream {
    static func ask(_ context: StudyPurpleContext, endpoint: URL,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        let bodyData: Data
        if let image = context.imagePNG {
            guard !image.isEmpty, image.count <= 180_000 else { throw StudyAIError.tooMuchInk }
            bodyData = try JSONEncoder().encode(StudyQuestion(question: nil, image: image.base64EncodedString()))
        } else if let question = context.recognizedText, (1...700).contains(question.count) {
            bodyData = try JSONEncoder().encode(StudyQuestion(question: question, image: nil))
        } else { throw StudyAIError.unreadable }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 48
        config.timeoutIntervalForResource = 55
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData
        guard bodyData.count <= (context.imagePNG == nil ? 2_000 : 250_000) else { throw StudyAIError.tooMuchInk }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "text/event-stream" else { throw StudyAIError.server }
        var total = 0
        var finished = false
        for try await line in stream.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "), let bytes = String(line.dropFirst(6)).data(using: .utf8),
                  bytes.count <= 5_000 else { continue }
            let event = try JSONDecoder().decode(StudyStreamEvent.self, from: bytes)
            if event.error != nil { throw StudyAIError.server }
            if let delta = event.delta {
                total += delta.count
                guard total <= 4_000 else { throw StudyAIError.server }
                await onText(delta)
            }
            if event.done == true { finished = true; break }
        }
        guard finished, total > 0 else { throw StudyAIError.server }
    }
}
