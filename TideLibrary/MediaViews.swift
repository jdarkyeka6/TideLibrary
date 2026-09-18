import AVKit
import Photos
import QuickLook
import QuickLookThumbnailing
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
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
            }

            if asset.isVideo {
                mediaBadge(symbol: "play.fill")
            } else if asset.isFavorite {
                mediaBadge(symbol: "heart.fill")
            }
        }
        .clipped()
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func mediaBadge(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
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
            targetSize: CGSize(width: 180 * scale, height: 180 * scale),
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

struct CloudThumbnail: View {
    let asset: CloudAssetRef
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(.white.opacity(0.06))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "externaldrive")
                    Text("DRIVE")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
            }

            if asset.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
        }
        .clipped()
        .task(id: asset.id) {
            guard image == nil else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: asset.url,
                size: CGSize(width: 360, height: 360),
                scale: UIScreen.main.scale,
                representationTypes: .thumbnail
            )

            do {
                let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                image = thumbnail.uiImage
            } catch {
                image = nil
            }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
