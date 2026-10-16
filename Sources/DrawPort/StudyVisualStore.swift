import Foundation

/// Independent visual sidecars leave PencilKit and older graph/page data intact.
/// Saving requires loading first; a corrupt sidecar is never replaced silently.
final class StudyVisualStore {
    private struct Document: Codable {
        let version: Int
        let notebook: UUID
        let page: UUID
        let assets: [StudyVisualAsset]
    }
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("InteractiveVisuals", isDirectory: true) }
    private func path(book: UUID, page: UUID) -> URL {
        root.appendingPathComponent(book.uuidString, isDirectory: true)
            .appendingPathComponent(page.uuidString + ".json")
    }
    func load(book: UUID, page: UUID, availableSources: Set<UUID>) throws -> [StudyVisualAsset] {
        let file = path(book: book, page: page)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 48_000 else { throw StudyVisualProtocolError.invalid }
        let saved = try JSONDecoder().decode(Document.self, from: data)
        guard saved.version == 1, saved.notebook == book, saved.page == page,
              saved.assets.count <= 8, Set(saved.assets.map(\.id)).count == saved.assets.count else {
            throw StudyVisualProtocolError.invalid
        }
        for asset in saved.assets { try asset.validate(availableSources: availableSources) }
        return saved.assets
    }
    func save(_ assets: [StudyVisualAsset], book: UUID, page: UUID,
              availableSources: Set<UUID>) throws {
        guard assets.count <= 8, Set(assets.map(\.id)).count == assets.count else {
            throw StudyVisualProtocolError.invalid
        }
        for asset in assets { try asset.validate(availableSources: availableSources) }
        _ = try load(book: book, page: page, availableSources: availableSources)
        let bytes = try JSONEncoder().encode(Document(version: 1, notebook: book, page: page, assets: assets))
        guard bytes.count <= 48_000 else { throw StudyVisualProtocolError.invalid }
        let file = path(book: book, page: page)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }
}
