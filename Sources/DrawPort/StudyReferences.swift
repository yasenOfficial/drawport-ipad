import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct StudyReference: Codable, Identifiable {
    var id: UUID
    var title: String
    var pages: Int
    var importedAt: Date
}

enum StudyReferenceError: LocalizedError {
    case invalidDocument
    var errorDescription: String? { "The PDF could not be imported or the saved reference library is invalid. Existing files were not changed." }
}

/// Local originals remain on the iPad. No document contents are sent to a
/// model, cloud service, or API merely by importing or searching a reference.
final class StudyReferenceStore {
    private struct Catalog: Codable {
        var version: Int = 1
        var references: [StudyReference] = []
    }
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("StudyReferences", isDirectory: true) }

    func all() throws -> [StudyReference] {
        let file = root.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count < 300_000 else { throw StudyReferenceError.invalidDocument }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version == 1, catalog.references.count <= 500,
              Set(catalog.references.map(\.id)).count == catalog.references.count,
              catalog.references.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 240 && (1...2000).contains($0.pages) }) else {
            throw StudyReferenceError.invalidDocument
        }
        return catalog.references
    }

    func file(for reference: StudyReference) -> URL {
        root.appendingPathComponent(reference.id.uuidString + ".pdf")
    }

    func importPDF(from url: URL) throws -> StudyReference {
        let original = try all() // Never overwrite an unreadable catalog.
        guard original.count < 500 else { throw StudyReferenceError.invalidDocument }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true, let size = resourceValues.fileSize,
              (1...80_000_000).contains(size) else { throw StudyReferenceError.invalidDocument }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == size, let pdf = PDFDocument(data: bytes),
              (1...2000).contains(pdf.pageCount) else { throw StudyReferenceError.invalidDocument }
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = String(name.prefix(240))
        let reference = StudyReference(id: UUID(), title: safeName.isEmpty ? "Untitled PDF" : safeName,
                                       pages: pdf.pageCount, importedAt: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = file(for: reference)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StudyReferenceError.invalidDocument }
        try bytes.write(to: destination, options: .atomic)
        do {
            let catalog = Catalog(references: original + [reference])
            let encoded = try JSONEncoder().encode(catalog)
            try encoded.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
        } catch {
            // Only the newly imported file is removed; never touch previous PDFs.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return reference
    }
}

/// A source citation can address a stable PDF ID, zero-based page, and an exact
/// quote. For scanned PDFs without a text layer we report no match, not a guess.
final class StudyReferenceViewer: UIViewController, UISearchBarDelegate {
    private let reference: StudyReference
    private let store: StudyReferenceStore
    private let pdfView = PDFView()
    private let search = UISearchBar()
    private var requestedCitation: (page: Int, quote: String)?

    init(reference: StudyReference, store: StudyReferenceStore, citation: (page: Int, quote: String)? = nil) {
        self.reference = reference
        self.store = store
        requestedCitation = citation
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = reference.title
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)
        search.placeholder = "Find an exact quote in this PDF"
        search.searchBarStyle = .minimal
        search.delegate = self
        pdfView.autoScales = true
        pdfView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        pdfView.document = PDFDocument(url: store.file(for: reference))
        guard pdfView.document?.pageCount == reference.pages else {
            showMessage("The source PDF is missing or cannot be read.")
            return
        }
        view.addSubview(search)
        view.addSubview(pdfView)
        search.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: search.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let citation = requestedCitation {
            requestedCitation = nil
            highlight(page: citation.page, quote: citation.quote)
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty, query.count <= 2000, let document = pdfView.document else { return }
        // An exact text match maps back to PDFKit's actual source selection.
        guard let selection = document.findString(query, withOptions: .caseInsensitive).first else {
            showMessage("No matching text found. Scanned pages may need OCR.")
            return
        }
        pdfView.currentSelection = selection
        pdfView.go(to: selection)
    }

    func highlight(page index: Int, quote: String) {
        guard let document = pdfView.document, let page = document.page(at: index),
              !quote.isEmpty, quote.count <= 2000 else { return }
        pdfView.go(to: page)
        let results = document.findString(quote, withOptions: .caseInsensitive)
        if let match = results.first(where: { $0.pages.contains(page) }) {
            pdfView.currentSelection = match
            pdfView.go(to: match)
        } else { showMessage("The quoted text was not found on this page.") }
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: "Reference", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

final class StudyReferenceLibrary: UITableViewController, UIDocumentPickerDelegate {
    private let store: StudyReferenceStore
    private var references: [StudyReference] = []

    init(store: StudyReferenceStore) {
        self.store = store
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Study references"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                             target: self, action: #selector(addPDF))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self, action: #selector(close))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reference")
        reload()
    }

    private func reload() {
        do { references = try store.all(); tableView.reloadData() }
        catch { report(error) }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { references.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reference", for: indexPath)
        let resource = references[indexPath.row]
        cell.textLabel?.text = "\(resource.title) · \(resource.pages) pages"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let viewer = StudyReferenceViewer(reference: references[indexPath.row], store: store)
        navigationController?.pushViewController(viewer, animated: true)
        tableView.deselectRow(at: indexPath, animated: true)
    }
    @objc private func addPDF() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let first = urls.first else { return }
        do { _ = try store.importPDF(from: first); reload() }
        catch { report(error) }
    }
    @objc private func close() { dismiss(animated: true) }
    private func report(_ error: Error) {
        let alert = UIAlertController(title: "Reference unavailable", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
