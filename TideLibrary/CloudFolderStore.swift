import Foundation
import UniformTypeIdentifiers

@MainActor
final class CloudFolderStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var assets: [CloudAssetRef] = []
    @Published private(set) var isIndexing = false
    @Published var errorMessage: String?

    private let bookmarkKey = "TideLibrary.CloudFolderBookmark"
    private var accessingURL: URL?

    init() {
        restoreBookmark()
    }

    deinit {
        accessingURL?.stopAccessingSecurityScopedResource()
    }

    var isConnected: Bool { rootURL != nil }

    var displayName: String {
        rootURL?.lastPathComponent ?? "No folder linked"
    }

    func connect(to url: URL) {
        stopAccess()

        let started = url.startAccessingSecurityScopedResource()
        if started {
            accessingURL = url
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            rootURL = url
            refresh()
        } catch {
            if started {
                url.stopAccessingSecurityScopedResource()
                accessingURL = nil
            }
            errorMessage = "Could not remember this cloud folder: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        stopAccess()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        rootURL = nil
        assets = []
    }

    func refresh() {
        guard let rootURL else { return }
        isIndexing = true

        Task {
            let result = await Self.scan(rootURL)
            self.assets = result.assets
            self.errorMessage = result.error
            self.isIndexing = false
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            let started = url.startAccessingSecurityScopedResource()
            if started {
                accessingURL = url
            }
            rootURL = url

            if stale {
                let refreshed = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }

            refresh()
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            errorMessage = "Your cloud folder link expired. Connect it again."
        }
    }

    private func stopAccess() {
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }

    private static func scan(_ root: URL) async -> (assets: [CloudAssetRef], error: String?) {
        await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [
                .contentTypeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .isRegularFileKey
            ]

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return ([], "TideLibrary could not read that folder.")
            }

            var found: [CloudAssetRef] = []
            found.reserveCapacity(256)

            while let url = enumerator.nextObject() as? URL {
                if found.count >= 10_000 { break }

                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let type = values.contentType else {
                    continue
                }

                let isImage = type.conforms(to: .image)
                let isVideo = type.conforms(to: .movie)
                guard isImage || isVideo else { continue }

                found.append(
                    CloudAssetRef(
                        url: url,
                        name: url.lastPathComponent,
                        createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                        isVideo: isVideo
                    )
                )
            }

            found.sort { $0.createdAt > $1.createdAt }
            return (found, nil)
        }.value
    }
}
