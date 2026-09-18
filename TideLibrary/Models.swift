import Foundation
import Photos

struct PhotoAssetRef: Identifiable, Hashable {
    let id: String
    let createdAt: Date
    let mediaType: PHAssetMediaType
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool

    var isVideo: Bool { mediaType == .video }

    var searchableText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy EEEE"
        return "\(isVideo ? "video" : "photo") \(formatter.string(from: createdAt))".lowercased()
    }
}

struct PhotoAlbumRef: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let coverAssetID: String?
}

struct CloudAssetRef: Identifiable, Hashable {
    let url: URL
    let name: String
    let createdAt: Date
    let isVideo: Bool

    var id: String { url.absoluteString }
}

enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case drive = "Drive"

    var id: String { rawValue }
}
