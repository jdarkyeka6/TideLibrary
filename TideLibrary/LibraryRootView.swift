import SwiftUI

struct LibraryRootView: View {
    @StateObject private var photos = PhotoLibraryStore()
    @StateObject private var vision = VisionIndexStore()

    var body: some View {
        TabView {
            PhotoTimelineView(photos: photos, vision: vision)
                .tabItem {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }

            PeopleView(photos: photos, vision: vision)
                .tabItem {
                    Label("People", systemImage: "person.2.fill")
                }

            SmartSearchView(photos: photos, vision: vision)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
        .tint(.white)
        .task {
            await photos.requestAccessIfNeeded()
        }
        .task(id: photos.assets.count) {
            guard photos.canRead else { return }
            vision.startIndexing(assets: photos.assets)
        }
        .alert(
            "TideLibrary",
            isPresented: Binding(
                get: { photos.errorMessage != nil },
                set: { value, _ in
                    if !value {
                        photos.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                photos.errorMessage = nil
            }
        } message: {
            Text(photos.errorMessage ?? "Unknown Photos error")
        }
    }
}

private struct PhotoSelection: Identifiable {
    let id: String
}

private struct PhotoTimelineView: View {
    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var vision: VisionIndexStore

    @State private var selection: PhotoSelection?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var monthGroups: [(title: String, assets: [PhotoAssetRef])] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: photos.assets) { asset in
            let parts = calendar.dateComponents(
                [.year, .month],
                from: asset.createdAt
            )

            return "\(parts.year ?? 0)-\(parts.month ?? 0)"
        }

        return grouped.values
            .compactMap { values -> (String, [PhotoAssetRef], Date)? in
                guard let newest = values.max(
                    by: { $0.createdAt < $1.createdAt }
                ) else {
                    return nil
                }

                let title = newest.createdAt.formatted(
                    .dateTime.month(.wide).year()
                )

                return (
                    title,
                    values.sorted { $0.createdAt > $1.createdAt },
                    newest.createdAt
                )
            }
            .sorted { $0.2 > $1.2 }
            .map { ($0.0, $0.1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !photos.canRead {
                    PhotosPermissionView(photos: photos)
                } else if photos.assets.isEmpty && photos.isLoading {
                    ProgressView("Loading Photos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.assets.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text(
                            "Your Apple Photos library will appear here."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(
                            spacing: 18,
                            pinnedViews: [.sectionHeaders]
                        ) {
                            ForEach(
                                Array(monthGroups.enumerated()),
                                id: \.offset
                            ) { _, group in
                                Section {
                                    LazyVGrid(
                                        columns: columns,
                                        spacing: 2
                                    ) {
                                        ForEach(group.assets) { asset in
                                            Button {
                                                selection = PhotoSelection(
                                                    id: asset.id
                                                )
                                            } label: {
                                                ApplePhotoThumbnail(
                                                    asset: asset
                                                )
                                                .aspectRatio(
                                                    1,
                                                    contentMode: .fit
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text(group.title)
                                            .font(.headline)

                                        Spacer()

                                        Text("\(group.assets.count)")
                                            .font(
                                                .caption.monospacedDigit()
                                            )
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.black.opacity(0.92))
                                }
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if vision.isIndexing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)

                            Text("\(vision.indexedCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(photos.assets.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .fullScreenCover(item: $selection) { selected in
            PhotoGalleryViewer(
                assets: photos.assets,
                initialID: selected.id
            )
        }
    }
}

private struct PeopleView: View {
    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var vision: VisionIndexStore

    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !photos.canRead {
                    PhotosPermissionView(photos: photos)
                } else if vision.people.isEmpty {
                    peopleEmptyState
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: columns,
                            spacing: 22
                        ) {
                            ForEach(
                                Array(vision.people.enumerated()),
                                id: \.element.id
                            ) { index, person in
                                NavigationLink {
                                    PersonDetailView(
                                        person: person,
                                        fallbackIndex: index,
                                        photos: photos,
                                        vision: vision
                                    )
                                } label: {
                                    VStack(spacing: 10) {
                                        FaceThumbnail(
                                            assetID:
                                                person.representativeAssetID,
                                            bounds:
                                                person.representativeFaceBounds
                                        )
                                        .aspectRatio(
                                            1,
                                            contentMode: .fit
                                        )

                                        VStack(spacing: 2) {
                                            Text(
                                                vision.displayName(
                                                    for: person,
                                                    fallbackIndex: index
                                                )
                                            )
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)

                                            Text("\(person.count) photos")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(18)

                        Text(
                            "People are grouped on this iPhone using on-device image analysis. TideLibrary does not upload faces."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("People")
        }
    }

    private var peopleEmptyState: some View {
        VStack(spacing: 18) {
            if vision.isIndexing {
                ProgressView(value: vision.progress)
                    .frame(maxWidth: 240)

                Text("Finding people…")
                    .font(.title3.bold())

                Text(
                    "\(vision.indexedCount) of \(vision.indexingTarget) recent photos checked"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("No people groups yet")
                    .font(.title3.bold())

                Text(
                    "Groups appear after TideLibrary finds the same face in more than one photo."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PersonDetailView: View {
    let person: PersonCluster
    let fallbackIndex: Int

    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var vision: VisionIndexStore

    @State private var selection: PhotoSelection?
    @State private var showRename = false
    @State private var nameDraft = ""

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var personAssets: [PhotoAssetRef] {
        vision.assets(
            for: person,
            in: photos.assets
        )
    }

    private var title: String {
        vision.displayName(
            for: person,
            fallbackIndex: fallbackIndex
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: columns,
                spacing: 2
            ) {
                ForEach(personAssets) { asset in
                    Button {
                        selection = PhotoSelection(id: asset.id)
                    } label: {
                        ApplePhotoThumbnail(asset: asset)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    nameDraft = vision.personNames[person.id] ?? ""
                    showRename = true
                } label: {
                    Label("Name", systemImage: "pencil")
                }
            }
        }
        .alert("Name this person", isPresented: $showRename) {
            TextField("Name", text: $nameDraft)

            Button("Save") {
                vision.setPersonName(
                    nameDraft,
                    for: person
                )
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Use this name in layered searches, for example “vids oct Jake”."
            )
        }
        .fullScreenCover(item: $selection) { selected in
            PhotoGalleryViewer(
                assets: personAssets,
                initialID: selected.id
            )
        }
    }
}

private struct SmartSearchView: View {
    @ObservedObject var photos: PhotoLibraryStore
    @ObservedObject var vision: VisionIndexStore

    @State private var query = ""
    @State private var results: [PhotoAssetRef] = []
    @State private var isSearching = false
    @State private var selection: PhotoSelection?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var trimmedQuery: String {
        query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if !photos.canRead {
                    PhotosPermissionView(photos: photos)
                } else if trimmedQuery.isEmpty {
                    searchHome
                } else if isSearching && results.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        HStack {
                            Text(
                                isSearching
                                    ? "Updating…"
                                    : "\(results.count) results"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        LazyVGrid(
                            columns: columns,
                            spacing: 2
                        ) {
                            ForEach(results) { asset in
                                Button {
                                    selection = PhotoSelection(
                                        id: asset.id
                                    )
                                } label: {
                                    ApplePhotoThumbnail(asset: asset)
                                        .aspectRatio(
                                            1,
                                            contentMode: .fit
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Search")
            .searchable(
                text: $query,
                placement:
                    .navigationBarDrawer(displayMode: .always),
                prompt: "vids oct Jake, dog 2026, receipt…"
            )
        }
        .task(id: query) {
            let searchText = trimmedQuery

            guard !searchText.isEmpty else {
                results = []
                isSearching = false
                return
            }

            isSearching = true

            do {
                try await Task.sleep(
                    nanoseconds: 220_000_000
                )
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            let nextResults = await vision.searchAsync(
                assets: photos.assets,
                query: searchText
            )

            guard !Task.isCancelled else { return }

            results = nextResults
            isSearching = false
        }
        .fullScreenCover(item: $selection) { selected in
            PhotoGalleryViewer(
                assets: results,
                initialID: selected.id
            )
        }
    }

    private var searchHome: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 24
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 8
                ) {
                    Text("Layer your search")
                        .font(.title2.bold())

                    Text(
                        "Every word can narrow the same result. Try a type + month + named person, like “vids oct Jake”."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ],
                    spacing: 10
                ) {
                    suggestion(
                        "Videos October",
                        symbol: "video.fill"
                    )

                    suggestion(
                        "Screenshots 2026",
                        symbol: "rectangle.on.rectangle"
                    )

                    suggestion(
                        "Dogs September",
                        symbol: "dog.fill"
                    )

                    suggestion(
                        "Receipts",
                        symbol: "doc.text"
                    )

                    suggestion(
                        "Favorites",
                        symbol: "heart.fill"
                    )

                    suggestion(
                        "People",
                        symbol: "person.2.fill"
                    )
                }

                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    HStack {
                        Text("On-device index")
                            .font(.headline)

                        Spacer()

                        Text(
                            "\(vision.records.count) smart photos"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    if vision.isIndexing {
                        ProgressView(value: vision.progress)

                        Text(
                            "Analysing recent photos without uploading them."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(
                            "Search index ready for this session."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(
                    .white.opacity(0.06),
                    in: RoundedRectangle(
                        cornerRadius: 18
                    )
                )
            }
            .padding(18)
        }
    }

    private func suggestion(
        _ title: String,
        symbol: String
    ) -> some View {
        Button {
            query = title
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)

                Text(title)
                    .font(.subheadline.bold())

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(
                .white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PhotosPermissionView: View {
    @ObservedObject var photos: PhotoLibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)

            Text("Connect Apple Photos")
                .font(.title3.bold())

            Text(
                "TideLibrary views your Photos and iCloud Photos without copying your whole library into the app."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)

            if photos.denied {
                Button("Open Settings") {
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else {
                        return
                    }

                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Photos Access") {
                    Task {
                        await photos.requestAccessIfNeeded()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}
