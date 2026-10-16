import Foundation
import UIKit

/// Only the private signer injects this tailnet HTTPS URL. No provider key,
/// study material, or private tailnet address is present in public source.
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

enum StudyAITransportError: LocalizedError {
    case badResponse, model(String)
    var errorDescription: String? {
        switch self {
        case .badResponse: "The study server did not provide a valid answer. Your notes were not sent."
        case .model(let text): text
        }
    }
}

/// A plain-text streaming answer. No suggestions are applied to the notebook;
/// closing the sheet cancels the request. A user explicitly types and confirms
/// the exact text sent. Only that text, not PencilKit/page/PDF data, is uploaded.
final class StudyAIAnswerController: UIViewController {
    private let endpoint: URL
    private let question: String
    private let answer = UITextView()
    private let progress = UILabel()
    private var operation: Task<Void, Never>?
    private var started = false

    init(endpoint: URL, question: String) {
        self.endpoint = endpoint
        self.question = question
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Study AI"
        view.backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                              target: self, action: #selector(close))
        let questionLabel = UILabel()
        questionLabel.text = "Question: " + question
        questionLabel.numberOfLines = 0
        questionLabel.font = .preferredFont(forTextStyle: .headline)
        questionLabel.textColor = .label
        progress.text = "Waiting for the free model…"
        progress.font = .preferredFont(forTextStyle: .footnote)
        progress.textColor = .secondaryLabel
        answer.isEditable = false
        answer.backgroundColor = .clear
        answer.font = .preferredFont(forTextStyle: .body)
        answer.textColor = .label
        answer.accessibilityIdentifier = "studyAI.streamingAnswer"
        let stack = UIStackView(arrangedSubviews: [questionLabel, progress, answer])
        stack.axis = .vertical
        stack.spacing = 12
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await self.stream() }
            catch is CancellationError { return }
            catch { self.progress.text = "Unavailable"; self.answer.text += "\n" + error.localizedDescription }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { operation?.cancel() }
    }
    @objc private func close() { operation?.cancel(); dismiss(animated: true) }

    private func stream() async throws {
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
        guard let body = request.httpBody, body.count <= 2_000 else { throw StudyAITransportError.badResponse }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "text/event-stream" else { throw StudyAITransportError.badResponse }
        progress.text = "Answering…"
        var total = 0
        var finished = false
        for try await line in stream.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "), let bytes = String(line.dropFirst(6)).data(using: .utf8),
                  bytes.count <= 5_000 else { continue }
            let event = try JSONDecoder().decode(StudyStreamEvent.self, from: bytes)
            if let error = event.error { throw StudyAITransportError.model(String(error.prefix(200))) }
            if let delta = event.delta {
                total += delta.count
                guard total <= 4_000 else { throw StudyAITransportError.badResponse }
                answer.text += delta
            }
            if event.done == true { finished = true; break }
        }
        guard finished, total > 0 else { throw StudyAITransportError.badResponse }
        progress.text = "Answer complete · text only · not saved to the notebook"
    }
}
