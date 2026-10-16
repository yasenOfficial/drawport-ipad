import Foundation
import PencilKit
import UIKit

/// A kept AI answer is an app-private page object, never PencilKit ink.
/// Preview text is not persisted until the student taps Keep on page.
struct StudyAnswerNote: Codable, Identifiable {
    var id: UUID
    var sourceSHA256: String
    var recognizedQuestion: String
    var answer: String
    // Reversible archive of ONLY the purple context strokes hidden at Keep.
    // Older page-answer sidecars decode with nil; no source ink is migrated.
    var hiddenPurpleInk: Data? = nil
    var x: Double
    var y: Double

    func validate() throws {
        guard sourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (2...700).contains(recognizedQuestion.count), (1...4_000).contains(answer.count),
              x.isFinite, y.isFinite, (0...4_000).contains(x), (0...4_000).contains(y),
              (hiddenPurpleInk?.count ?? 0) <= 1_000_000 else {
            throw StudyAIError.server
        }
        if let hiddenPurpleInk {
            guard let drawing = try? PKDrawing(data: hiddenPurpleInk),
                  !drawing.strokes.isEmpty, drawing.strokes.count <= 1_200,
                  drawing.strokes.allSatisfy({ QuestionInk.matches($0.ink.color) }) else {
                throw StudyAIError.server
            }
        }
    }
}

final class StudyAnswerStore {
    private struct Document: Codable {
        var version: Int
        var notebook: UUID
        var page: UUID
        var notes: [StudyAnswerNote]
    }
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("StudyAnswers", isDirectory: true) }
    private func path(book: UUID, page: UUID) -> URL {
        root.appendingPathComponent(book.uuidString, isDirectory: true)
            .appendingPathComponent(page.uuidString + ".json")
    }
    func load(book: UUID, page: UUID) throws -> [StudyAnswerNote] {
        let file = path(book: book, page: page)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_500_000 else { throw StudyAIError.server }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard [1, 2].contains(document.version), document.notebook == book, document.page == page,
              document.notes.count <= 8, Set(document.notes.map(\.id)).count == document.notes.count else {
            throw StudyAIError.server
        }
        try document.notes.forEach { try $0.validate() }
        return document.notes
    }
    func save(_ notes: [StudyAnswerNote], book: UUID, page: UUID) throws {
        guard notes.count <= 8, Set(notes.map(\.id)).count == notes.count else { throw StudyAIError.server }
        try notes.forEach { try $0.validate() }
        _ = try load(book: book, page: page) // Preserve an unreadable sidecar.
        let bytes = try JSONEncoder().encode(Document(version: 2, notebook: book, page: page, notes: notes))
        guard bytes.count <= 1_500_000 else { throw StudyAIError.server }
        let file = path(book: book, page: page)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }
}

/// A sheet-like card ON the paper: OCR preview, streaming answer and Keep on
/// page all happen in the notebook coordinate system, not in a modal window.
final class StudyAnswerCard: UIView {
    static let cardSize = CGSize(width: 460, height: 310)
    var onSend: (() -> Void)?
    var onKeep: ((String, CGPoint) -> Void)?
    var onClose: (() -> Void)?
    private let pageSize: CGSize
    private let titleLabel = UILabel()
    private let status = UILabel()
    private let text = UITextView()
    private let previewImage = UIImageView()
    private let sendButton = UIButton(type: .system)
    private let keepButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private(set) var response = ""
    private var saved = false

    init(pageSize: CGSize, origin: CGPoint = CGPoint(x: 48, y: 90), saved note: StudyAnswerNote? = nil) {
        self.pageSize = pageSize
        let x = min(max(0, origin.x), max(0, pageSize.width - Self.cardSize.width))
        let y = min(max(0, origin.y), max(0, pageSize.height - Self.cardSize.height))
        super.init(frame: CGRect(origin: CGPoint(x: x, y: y), size: Self.cardSize))
        backgroundColor = UIColor(red: 1, green: 0.99, blue: 0.94, alpha: 0.98)
        layer.cornerRadius = 12
        layer.borderWidth = 2
        layer.borderColor = QuestionInk.color.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 7
        accessibilityIdentifier = "studyAI.pageAnswer"
        titleLabel.text = "✦  Study AI · on this page"
        titleLabel.textColor = .black
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragCard(_:))))
        closeButton.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        closeButton.accessibilityLabel = note == nil ? "Discard answer preview" : "Remove saved answer"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        closeButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.heightAnchor.constraint(equalToConstant: 35).isActive = true
        status.font = .systemFont(ofSize: 13)
        status.textColor = .darkGray
        status.numberOfLines = 2
        status.heightAnchor.constraint(equalToConstant: 37).isActive = true
        text.backgroundColor = .clear
        text.font = .systemFont(ofSize: 17)
        text.textColor = .black
        text.isEditable = false
        text.accessibilityIdentifier = "studyAI.pageText"
        previewImage.contentMode = .scaleAspectFit
        previewImage.backgroundColor = .white
        previewImage.isHidden = true
        previewImage.accessibilityLabel = "Preview of ink inside the purple circle"
        sendButton.setTitle("Send recognized purple text", for: .normal)
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        keepButton.setTitle("Keep answer on page", for: .normal)
        keepButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.response.isEmpty else { return }
            self.onKeep?(self.response, self.frame.origin)
        }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [sendButton, keepButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let stack = UIStackView(arrangedSubviews: [header, status, previewImage, text, actions])
        stack.axis = .vertical
        stack.spacing = 5
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        if let note {
            saved = true
            response = note.answer
            status.text = "Kept on this page · recognized purple: \(note.recognizedQuestion.prefix(90))"
            text.text = note.answer
            sendButton.isHidden = true
            keepButton.isHidden = true
            accessibilityIdentifier = "studyAI.savedAnswer.\(note.id.uuidString)"
        } else { showStatus("Reading purple handwriting on this iPad…") }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showStatus(_ message: String) {
        status.text = message
        sendButton.isHidden = true
        keepButton.isHidden = true
    }
    func showPreview(_ recognized: String) {
        status.text = "Check OCR below. Only this text is sent; no image or PDF."
        previewImage.isHidden = true
        text.isHidden = false
        text.text = recognized
        sendButton.setTitle("Send recognized purple text", for: .normal)
        sendButton.isHidden = false
        keepButton.isHidden = true
    }
    func showEnclosurePreview(_ png: Data) {
        status.text = "Only this circled image goes to the free vision model. Check it first."
        previewImage.image = UIImage(data: png)
        previewImage.isHidden = false
        text.isHidden = true
        sendButton.setTitle("Send circled image", for: .normal)
        sendButton.isHidden = false
        keepButton.isHidden = true
    }
    func beginAnswer() {
        response = ""
        previewImage.isHidden = true
        text.isHidden = false
        text.text = ""
        showStatus("Answering on this page…")
    }
    func appendAnswer(_ delta: String) {
        response += delta
        text.text = response
    }
    func finishAnswer() {
        status.text = "Preview only · Keep to save on this page; otherwise ✕ discards it."
        keepButton.isHidden = false
    }
    func showSaveFailure(_ message: String) {
        status.text = String(message.prefix(140))
        keepButton.isHidden = false
    }
    func markSaved() {
        saved = true
        status.text = "Kept on this page"
        keepButton.isHidden = true
        sendButton.isHidden = true
        closeButton.accessibilityLabel = "Remove saved answer"
    }
    @objc private func dragCard(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        let delta = gesture.translation(in: parent)
        if gesture.state == .changed {
            frame.origin.x = min(max(0, frame.minX + delta.x), max(0, pageSize.width - bounds.width))
            frame.origin.y = min(max(0, frame.minY + delta.y), max(0, pageSize.height - bounds.height))
            gesture.setTranslation(.zero, in: parent)
        } else if gesture.state == .ended, saved {
            onKeep?(response, frame.origin) // Atomically persist a moved saved card.
        }
    }
}
