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

private struct StudyQuestion: Encodable { let version = 1; let question: String }
private struct StudyStreamEvent: Decodable { let delta: String?; let error: String?; let done: Bool? }

enum StudyAIError: LocalizedError {
    case noPurpleInk, tooMuchInk, unreadable, server
    var errorDescription: String? {
        switch self {
        case .noPurpleInk: "Write the question in purple ink on this page first. No data was sent."
        case .tooMuchInk: "The purple area is too large to read safely. No data was sent."
        case .unreadable: "The iPad could not read the purple handwriting. No data was sent. Try writing it more clearly in purple."
        case .server: "Study AI is unavailable. The notebook was not changed."
        }
    }
}

struct StudyPurpleContext {
    let recognizedText: String
    let sourceHash: String
    let bounds: CGRect
}

/// Strictly filter semantic purple Pencil strokes BEFORE creating the OCR
/// bitmap. Vision runs on-device. Neither bitmap nor other ink/PDF leaves the
/// iPad. OCR text is shown on the actual page for confirmation before upload.
enum StudyPurpleCapture {
    @MainActor static func recognize(_ drawing: PKDrawing) async throws -> StudyPurpleContext {
        let strokes = drawing.strokes.filter { QuestionInk.matches($0.ink.color) }
        guard !strokes.isEmpty else { throw StudyAIError.noPurpleInk }
        guard strokes.count <= 1_200 else { throw StudyAIError.tooMuchInk }
        let purple = PKDrawing(strokes: strokes)
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
            request.usesLanguageCorrection = false // Prefer equations to autocorrected prose.
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
        return StudyPurpleContext(recognizedText: text, sourceHash: sourceHash, bounds: raw)
    }
}

/// Bounded streaming plain text. The host accepts only {version,question}; no
/// legacy notebook capture, strokes, PDF or automatic graph proposal are sent.
enum StudyAIStream {
    static func ask(_ question: String, endpoint: URL,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        guard (1...700).contains(question.count) else { throw StudyAIError.unreadable }
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
        request.httpBody = try JSONEncoder().encode(StudyQuestion(question: question))
        guard let body = request.httpBody, body.count <= 2_000 else { throw StudyAIError.unreadable }
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
