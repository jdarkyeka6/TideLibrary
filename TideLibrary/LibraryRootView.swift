import SwiftUI
import UniformTypeIdentifiers

struct LibraryRootView: View {
    @StateObject private var photos = PhotoLibraryStore()
    @StateObject private var cloud = CloudFolderStore()

    var body: some View {
        TabView {
            PhotosScreen(photos: photos, cloud: cloud)
                .tabItem {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }

            AlbumsScreen(photos: photos)
                .tabItem {
                    Label("Albums", systemImage: "rectangle.stack")
                }

            SourcesScreen(photos: photos, cloud: cloud)
                .tabItem {
                    Label("Sources", systemImage: "externaldrive.connected.to.line.below")
                }
        }
        .tint(.white)
        .task {
            await photos.requestAccessIfNeeded()
        }
        .alert("TideLibrary", isPresented: Binding(
            get: { photos.errorMessage != nil || cloud.errorMessage != nil },
            set: {
                if !$0 {
                    photos.errorMessage = nil
                    cloud.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                photos.errorMessage = nil
                cloud.errorMessage = nil
            }
        } message: {
            Text(photos.errorMessage ?? cloud.errorMessage ?? "Unknown library error")
        }
    }
}

private enum UnifiedAsset: Identifiable {
    case photo(PhotoAssetRef)
    case cloud(CloudAssetRef)

    var id: String {
        switch self {
        case .photo(let asset): return "photos:\(asset.id)"
        case .cloud(let asset): return "drive:\(asset.id)"
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let asset): return asset.createdAt
        case .cloud(let asset): return asset.createdAt
        }
    }
}

private struct PhotosScreen: View {
    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var cloud: CloudFolderStore

    @State private var source: LibrarySourceFilter = .all
    @State private var query = ""
    @State private var selectedPhotoID: String?
    @State private var selectedCloud: CloudAssetRef?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var filteredPhotos: [PhotoAssetRef] {
        guard !query.isEmpty else { return photos.assets }
        let needle = query.lowercased()
        return photos.assets.filter { $0.searchableText.contains(needle) }
    }

    private var filteredCloud: [CloudAssetRef] {
        guard !query.isEmpty else { return cloud.assets }
        let needle = query.lowercased()
        return cloud.assets.filter { $0.name.lowercased().contains(needle) }
    }

    private var visibleItems: [UnifiedAsset] {
        switch source {
        case .photos:
            return filteredPhotos.map(UnifiedAsset.photo)
        case .drive:
            return filteredCloud.map(UnifiedAsset.cloud)
        case .all:
            return (
                filteredPhotos.map(UnifiedAsset.photo) +
                filteredCloud.map(UnifiedAsset.cloud)
            )
            .sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $source) {
                    ForEach(LibrarySourceFilter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                content
            }
            .background(Color.black)
            .navigationTitle("TideLibrary")
            .searchable(text: $query, prompt: "Search photos, dates or Drive files")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if photos.isLoading || cloud.isIndexing {
                        ProgressView()
                    } else {
                        Button {
                            photos.reload()
                            cloud.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: {
                guard let selectedPhotoID else { return nil }
                return PhotoSelection(id: selectedPhotoID)
            },
            set: { value in
                selectedPhotoID = value?.id
            }
        )) { selection in
            PhotoGalleryViewer(
                assets: filteredPhotos,
                initialID: selection.id
            )
        }
        .fullScreenCover(item: $selectedCloud) { asset in
            CloudFileViewer(asset: asset)
        }
    }

    @ViewBuilder
    private var content: some View {
        if source != .drive && photos.needsPermission {
            permissionPrompt
        } else if visibleItems.isEmpty {
            ContentUnavailableView(
                source == .drive ? "No Drive media" : "No photos yet",
                systemImage: source == .drive ? "externaldrive" : "photo.stack",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(visibleItems) { item in
                        Button {
                            switch item {
                            case .photo(let asset):
                                selectedPhotoID = asset.id
                            case .cloud(let asset):
                                selectedCloud = asset
                            }
                        } label: {
                            Group {
                                switch item {
                                case .photo(let asset):
                                    ApplePhotoThumbnail(asset: asset)
                                case .cloud(let asset):
                                    CloudThumbnail(asset: asset)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Connect Apple Photos")
                .font(.title3.bold())
            Text("TideLibrary shows your iCloud Photos without duplicating your whole library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Allow Photos Access") {
                Task { await photos.requestAccessIfNeeded() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        if source == .drive {
            return cloud.isConnected
                ? "No supported photos or videos were found in \(cloud.displayName)."
                : "Connect a Google Drive folder from the Sources tab."
        }
        if photos.denied {
            return "Photos access is off. You can enable it in Settings."
        }
        return "Your library will appear here."
    }
}

private struct PhotoSelection: Identifiable {
    let id: String
}

private struct AlbumsScreen: View {
    @ObservedObject var photos: PhotoLibraryStore

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if photos.albums.isEmpty {
                    ContentUnavailableView(
                        "No albums",
                        systemImage: "rectangle.stack",
                        description: Text("Your Apple Photos albums will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(photos.albums) { album in
                                NavigationLink {
                                    AlbumDetailView(album: album, photos: photos)
                                } label: {
                                    AlbumCard(album: album, photos: photos)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Albums")
        }
    }
}

private struct AlbumCard: View {
    let album: PhotoAlbumRef
    @ObservedObject var photos: PhotoLibraryStore

    private var cover: PhotoAssetRef? {
        guard let id = album.coverAssetID else { return nil }
        return photos.assets.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.07))

                if let cover {
                    ApplePhotoThumbnail(asset: cover)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(album.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(album.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlbumDetailView: View {
    let album: PhotoAlbumRef
    @ObservedObject var photos: PhotoLibraryStore
    @State private var selectedID: String?

    private var albumAssets: [PhotoAssetRef] {
        photos.assets(in: album)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(albumAssets) { asset in
                    Button {
                        selectedID = asset.id
                    } label: {
                        ApplePhotoThumbnail(asset: asset)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: Binding(
            get: {
                guard let selectedID else { return nil }
                return PhotoSelection(id: selectedID)
            },
            set: { selectedID = $0?.id }
        )) { selection in
            PhotoGalleryViewer(assets: albumAssets, initialID: selection.id)
        }
    }
}

private struct SourcesScreen: View {
    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var cloud: CloudFolderStore
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Apple") {
                    sourceRow(
                        icon: "photo.stack.fill",
                        title: "Apple Photos + iCloud",
                        detail: photos.canRead
                            ? "\(photos.assets.count) items available"
                            : "Not connected",
                        connected: photos.canRead
                    )

                    if photos.denied {
                        Button("Open Photos Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                    } else if !photos.canRead {
                        Button("Connect Apple Photos") {
                            Task { await photos.requestAccessIfNeeded() }
                        }
                    }
                }

                Section("Cloud") {
                    sourceRow(
                        icon: "externaldrive.fill",
                        title: "Google Drive / Files",
                        detail: cloud.isConnected
                            ? "\(cloud.displayName) · \(cloud.assets.count) media items"
                            : "Choose a folder from Google Drive in Files",
                        connected: cloud.isConnected
                    )

                    if cloud.isConnected {
                        Button("Refresh linked folder") {
                            cloud.refresh()
                        }
                        Button("Change folder") {
                            showFolderPicker = true
                        }
                        Button("Disconnect", role: .destructive) {
                            cloud.disconnect()
                        }
                    } else {
                        Button("Connect Google Drive Folder") {
                            showFolderPicker = true
                        }
                    }
                }

                Section {
                    Text("TideLibrary indexes references and thumbnails. It does not copy your entire Apple Photos or cloud library into the app. Full media is requested only when you open it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sources")
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    cloud.connect(to: url)
                }
            case .failure(let error):
                cloud.errorMessage = "Could not connect folder: \(error.localizedDescription)"
            }
        }
    }

    private func sourceRow(
        icon: String,
        title: String,
        detail: String,
        connected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(connected ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct CloudFileViewer: View {
    @Environment(\.dismiss) private var dismiss
    let asset: CloudAssetRef

    var body: some View {
        NavigationStack {
            QuickLookView(url: asset.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(asset.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
