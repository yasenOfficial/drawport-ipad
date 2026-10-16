import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct StudyReference: Codable, Identifiable {
    var id: UUID
    var title: String
    var pages: Int
    var importedAt: Date
    // Nil is Unassigned; old imported PDFs decode with nil without migration.
    var folderID: UUID? = nil
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

    /// Mirrors the existing notebook folder ID; PDF bytes remain in one library.
    func importPDF(from url: URL, folderID: UUID? = nil) throws -> StudyReference {
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
                                       pages: pdf.pageCount, importedAt: Date(), folderID: folderID)
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

    /// Reassign only catalog metadata. Never move/delete the original PDF bytes.
    func move(_ id: UUID, to folderID: UUID?) throws {
        var references = try all()
        guard let index = references.firstIndex(where: { $0.id == id }) else { throw StudyReferenceError.invalidDocument }
        references[index].folderID = folderID
        try JSONEncoder().encode(Catalog(references: references))
            .write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
    }

    /// Hard scope: only the exact active notebook folder, plus exact PDF IDs
    /// explicitly pinned in this session. Child/old-semester folders are NEVER
    /// included automatically merely because they share a parent folder.
    /// Dates/tags never widen this scope automatically.
    func eligible(folderID: UUID?, folders: [Folder], pinnedIDs: Set<UUID> = []) throws -> [StudyReference] {
        let known = Set(folders.map(\.id))
        return try all().filter { resource in
            if pinnedIDs.contains(resource.id) { return true }
            let assigned = resource.folderID.flatMap { known.contains($0) ? $0 : nil }
            // A removed folder is browsable as Unassigned but must not become
            // automatically eligible for an unrelated root notebook.
            guard resource.folderID == nil || assigned != nil else { return false }
            return assigned == folderID
        }
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
    private let notebooks: Store
    private let activeNotebookFolderID: UUID?
    private let activeNotebookID: UUID?
    var onPinsChange: ((Set<UUID>) -> Void)?
    private var pinnedIDs: Set<UUID>
    private var browsingFolderID: UUID?
    private var references: [StudyReference] = []
    private var childFolders: [Folder] = []
    private var eligibleIDs: Set<UUID> = []

    init(store: StudyReferenceStore, notebooks: Store, activeNotebookID: UUID?,
         activeNotebookFolderID: UUID?, pinnedIDs: Set<UUID>) {
        self.store = store
        self.notebooks = notebooks
        self.activeNotebookID = activeNotebookID
        self.activeNotebookFolderID = activeNotebookFolderID
        self.pinnedIDs = pinnedIDs
        browsingFolderID = activeNotebookFolderID
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                             target: self, action: #selector(addPDF))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reference")
        reload()
    }

    private func reload() {
        let folders = notebooks.folders
        if let id = browsingFolderID, !folders.contains(where: { $0.id == id }) { browsingFolderID = nil }
        childFolders = folders.filter { $0.parentID == browsingFolderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            // Orphaned assignments from a removed notebook folder remain safely
            // visible as Unassigned, never silently deleted with that folder.
            let known = Set(folders.map(\.id))
            references = try store.all().filter { resource in
                let resolved = resource.folderID.flatMap { known.contains($0) ? $0 : nil }
                return resolved == browsingFolderID
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { references = []; report(error) }
        title = browsingFolderID.flatMap { Folder.path(of: $0, in: folders) } ?? "Resources"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: browsingFolderID == nil ? "Done" : "Back",
                                                            style: .plain, target: self, action: #selector(back))
        let current = activeNotebookFolderID.flatMap { Folder.path(of: $0, in: folders) }
        let scope = current ?? "Unassigned"
        eligibleIDs = Set((try? store.eligible(folderID: activeNotebookFolderID, folders: folders,
                                                pinnedIDs: pinnedIDs))?.map(\.id) ?? [])
        let eligibleCount = eligibleIDs.count
        let label = UILabel(frame: CGRect(x: 16, y: 8, width: max(250, tableView.bounds.width - 32), height: 76))
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.text = "Selected for notebook: \(scope) · \(eligibleCount) PDF(s). ✓ marks included files; swipe a PDF to pin it explicitly. AI is not connected yet."
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 94))
        header.addSubview(label)
        label.autoresizingMask = [.flexibleWidth]
        tableView.tableHeaderView = header
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Folders" : "PDFs in this folder"
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? childFolders.count : references.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reference", for: indexPath)
        if indexPath.section == 0 {
            cell.textLabel?.text = "📁  \(childFolders[indexPath.row].name)"
        } else {
            let resource = references[indexPath.row]
            let active = eligibleIDs.contains(resource.id)
            cell.textLabel?.text = "\(active ? "✓ " : "")\(resource.title) · \(resource.pages) pages"
            cell.accessibilityLabel = "\(active ? "In this notebook's reference scope" : "Outside this notebook's reference scope"), \(resource.title)"
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 {
            browsingFolderID = childFolders[indexPath.row].id
            reload()
        } else {
            let viewer = StudyReferenceViewer(reference: references[indexPath.row], store: store)
            navigationController?.pushViewController(viewer, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let resource = references[indexPath.row]
        let move = UIContextualAction(style: .normal, title: "Move PDF") { [weak self] _, _, done in
            self?.chooseFolder(for: resource)
            done(true)
        }
        guard activeNotebookID != nil,
              !eligibleIDs.contains(resource.id) || pinnedIDs.contains(resource.id) else {
            return UISwipeActionsConfiguration(actions: [move])
        }
        let pinned = pinnedIDs.contains(resource.id)
        let pin = UIContextualAction(style: .normal, title: pinned ? "Unpin" : "Pin for this notebook") { [weak self] _, _, done in
            guard let self else { done(false); return }
            if pinned { self.pinnedIDs.remove(resource.id) }
            else { self.pinnedIDs.insert(resource.id) }
            self.onPinsChange?(self.pinnedIDs)
            self.reload()
            done(true)
        }
        pin.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [pin, move])
    }
    private func chooseFolder(for resource: StudyReference) {
        let sheet = UIAlertController(title: "Move \(resource.title)", message: "Move the catalog entry, not the PDF contents.", preferredStyle: .actionSheet)
        let choices: [(String, UUID?)] = [("Unassigned", nil)] + notebooks.folderDestinations().map {
            (Folder.path(of: $0.id, in: notebooks.folders) ?? $0.name, Optional($0.id))
        }
        for (name, folderID) in choices.prefix(100) {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                guard let self else { return }
                do { try self.store.move(resource.id, to: folderID); self.reload() }
                catch { self.report(error) }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }
    @objc private func addPDF() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let first = urls.first else { return }
        do { _ = try store.importPDF(from: first, folderID: browsingFolderID); reload() }
        catch { report(error) }
    }
    @objc private func back() {
        guard let id = browsingFolderID else { dismiss(animated: true); return }
        browsingFolderID = notebooks.folders.first(where: { $0.id == id })?.parentID
        reload()
    }
    private func report(_ error: Error) {
        let alert = UIAlertController(title: "Reference unavailable", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
