import Foundation
import Photos

@MainActor
final class PhotoLibraryStore: ObservableObject {
    @Published private(set) var assets: [PhotoAssetRef] = []
    @Published private(set) var albums: [PhotoAlbumRef] = []
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published var isLoading = false
    @Published var errorMessage: String?

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if canRead {
            reload()
        }
    }

    var canRead: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var needsPermission: Bool {
        authorizationStatus == .notDetermined
    }

    var denied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestAccessIfNeeded() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            authorizationStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authorizationStatus = current
        }

        if canRead {
            reload()
        }
    }

    func reload() {
        guard canRead else {
            assets = []
            albums = []
            return
        }

        isLoading = true

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)

        var nextAssets: [PhotoAssetRef] = []
        nextAssets.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            nextAssets.append(Self.makeAssetRef(asset))
        }

        assets = nextAssets
        albums = loadAlbums()
        isLoading = false
    }

    func assets(in album: PhotoAlbumRef) -> [PhotoAssetRef] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [album.id],
            options: nil
        ).firstObject else {
            return []
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: collection, options: options)

        var values: [PhotoAssetRef] = []
        values.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            values.append(Self.makeAssetRef(asset))
        }
        return values
    }

    private func loadAlbums() -> [PhotoAlbumRef] {
        var result: [PhotoAlbumRef] = []
        var seen = Set<String>()

        func appendCollections(_ collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                guard !seen.contains(collection.localIdentifier) else { return }

                let fetch = PHAsset.fetchAssets(in: collection, options: nil)
                guard fetch.count > 0 else { return }

                let cover = fetch.lastObject?.localIdentifier
                result.append(
                    PhotoAlbumRef(
                        id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "Album",
                        count: fetch.count,
                        coverAssetID: cover
                    )
                )
                seen.insert(collection.localIdentifier)
            }
        }

        appendCollections(
            PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .any,
                options: nil
            )
        )

        appendCollections(
            PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: nil
            )
        )

        return result.sorted {
            if $0.title == "Recents" { return true }
            if $1.title == "Recents" { return false }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func makeAssetRef(_ asset: PHAsset) -> PhotoAssetRef {
        PhotoAssetRef(
            id: asset.localIdentifier,
            createdAt: asset.creationDate ?? .distantPast,
            mediaType: asset.mediaType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite
        )
    }
}
