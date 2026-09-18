import Foundation
import Photos

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var assets: [PhotoAssetRef] = []
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published var isLoading = false
    @Published var errorMessage: String?

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        PHPhotoLibrary.shared().register(self)

        if canRead {
            reload()
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
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
        isLoading = false
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            self?.reload()
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
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
        )
    }
}
