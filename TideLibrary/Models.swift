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
    let isScreenshot: Bool
    let isLivePhoto: Bool

    var isVideo: Bool { mediaType == .video }

    var searchableText: String {
        let month = createdAt.formatted(.dateTime.month(.wide).year().day())
        let weekday = createdAt.formatted(.dateTime.weekday(.wide))
        var parts = [
            isVideo ? "video movie clip" : "photo image picture",
            month,
            weekday
        ]
        if isFavorite { parts.append("favorite favourite") }
        if isScreenshot { parts.append("screenshot screen capture") }
        if isLivePhoto { parts.append("live photo") }
        return parts.joined(separator: " ").lowercased()
    }
}

struct SmartSearchRecord: Codable, Hashable {
    let assetID: String
    let labels: [String]
    let recognizedText: String
    let faceCount: Int

    var searchableText: String {
        (labels.joined(separator: " ") + " " + recognizedText).lowercased()
    }
}

struct FaceBounds: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PersonCluster: Identifiable, Codable, Hashable {
    let id: String
    let representativeAssetID: String
    let representativeFaceBounds: FaceBounds
    let assetIDs: [String]

    var count: Int { assetIDs.count }
}
