import Photos
import SwiftUI

private let tidePhotoImageManager = PHCachingImageManager()

struct ApplePhotoThumbnail: View {
    let asset: PhotoAssetRef
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(.white.opacity(0.06))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if asset.isLivePhoto {
                    Image(systemName: "livephoto")
                }
                if asset.isVideo {
                    Image(systemName: "play.fill")
                }
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(6)
            .opacity((asset.isLivePhoto || asset.isVideo || asset.isFavorite) ? 1 : 0)
        }
        .clipped()
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func load() {
        guard image == nil,
              let phAsset = PHAsset.fetchAssets(
                withLocalIdentifiers: [asset.id],
                options: nil
              ).firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let scale = UIScreen.main.scale
        requestID = tidePhotoImageManager.requestImage(
            for: phAsset,
            targetSize: CGSize(width: 190 * scale, height: 190 * scale),
            contentMode: .aspectFill,
            options: options
        ) { value, _ in
            guard let value else { return }
            DispatchQueue.main.async {
                image = value
            }
        }
    }

    private func cancel() {
        guard requestID != PHInvalidImageRequestID else { return }
        tidePhotoImageManager.cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

struct FaceThumbnail: View {
    let assetID: String
    let bounds: FaceBounds

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.07))

            if let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(Circle())
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func load() {
        guard image == nil,
              let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetID],
                options: nil
              ).firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 420, height: 420),
            contentMode: .aspectFit,
            options: options
        ) { value, info in
            guard let value else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !degraded else { return }

            DispatchQueue.main.async {
                self.image = Self.crop(value, normalizedBounds: bounds.cgRect)
            }
        }
    }

    private func cancel() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }

    private static func crop(
        _ image: UIImage,
        normalizedBounds: CGRect
    ) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        var rect = CGRect(
            x: normalizedBounds.minX * width,
            y: (1 - normalizedBounds.maxY) * height,
            width: normalizedBounds.width * width,
            height: normalizedBounds.height * height
        )

        let padding = max(rect.width, rect.height) * 0.35
        rect = rect.insetBy(dx: -padding, dy: -padding)

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        rect = rect.intersection(imageRect).integral

        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }
}
