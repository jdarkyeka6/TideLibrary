import AVKit
import Photos
import SwiftUI

struct PhotoGalleryViewer: View {
    @Environment(\.dismiss) private var dismiss

    let assets: [PhotoAssetRef]
    let initialID: String

    @State private var selection: String
    @State private var showInfo = false

    init(assets: [PhotoAssetRef], initialID: String) {
        self.assets = assets
        self.initialID = initialID
        _selection = State(initialValue: initialID)
    }

    private var selectedAsset: PhotoAssetRef? {
        assets.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(assets) { asset in
                    PhotoPage(asset: asset)
                        .tag(asset.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    if let selectedAsset {
                        Text(dateText(selectedAsset.createdAt))
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                if let selectedAsset {
                    HStack(spacing: 8) {
                        if selectedAsset.isVideo {
                            Label(durationText(selectedAsset.duration), systemImage: "video.fill")
                        } else {
                            Label(
                                "\(selectedAsset.pixelWidth) × \(selectedAsset.pixelHeight)",
                                systemImage: "photo"
                            )
                        }

                        if selectedAsset.isFavorite {
                            Image(systemName: "heart.fill")
                        }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let asset = selectedAsset {
                PhotoInfoSheet(asset: asset)
                    .presentationDetents([.medium])
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func durationText(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PhotoPage: View {
    let asset: PhotoAssetRef

    var body: some View {
        if asset.isVideo {
            AppleVideoView(assetID: asset.id)
        } else {
            AppleZoomablePhoto(assetID: asset.id)
        }
    }
}

private struct AppleZoomablePhoto: View {
    let assetID: String

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(lastScale * value, 1), 6)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale < 1.05 {
                                        withAnimation(.snappy) {
                                            scale = 1
                                            lastScale = 1
                                        }
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                if scale > 1.1 {
                                    scale = 1
                                    lastScale = 1
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                }
                            }
                        }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading from Photos…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

        let scale = UIScreen.main.scale
        let target = CGSize(
            width: UIScreen.main.bounds.width * scale * 2,
            height: UIScreen.main.bounds.height * scale * 2
        )

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                if let result {
                    image = result
                }
                if !degraded && result == nil {
                    image = nil
                }
            }
        }
    }

    private func cancel() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

private struct AppleVideoView: View {
    let assetID: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading video from Photos…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: assetID) {
            guard player == nil,
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [assetID],
                    options: nil
                  ).firstObject else { return }

            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { item, _ in
                guard let item else { return }
                DispatchQueue.main.async {
                    player = AVPlayer(playerItem: item)
                }
            }
        }
    }
}

private struct PhotoInfoSheet: View {
    let asset: PhotoAssetRef

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(
                    "Type",
                    value: asset.isVideo ? "Video" : "Photo"
                )
                LabeledContent(
                    "Date",
                    value: asset.createdAt.formatted(date: .long, time: .shortened)
                )
                LabeledContent(
                    "Resolution",
                    value: "\(asset.pixelWidth) × \(asset.pixelHeight)"
                )
                if asset.isVideo {
                    LabeledContent(
                        "Duration",
                        value: String(format: "%.1f sec", asset.duration)
                    )
                }
                LabeledContent(
                    "Source",
                    value: "Apple Photos / iCloud"
                )
                LabeledContent(
                    "TideLibrary copy",
                    value: "None"
                )
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
