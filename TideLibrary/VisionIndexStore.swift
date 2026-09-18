import Foundation
import Photos
import UIKit
import Vision

@MainActor
final class VisionIndexStore: ObservableObject {
    @Published private(set) var records: [String: SmartSearchRecord] = [:]
    @Published private(set) var people: [PersonCluster] = []
    @Published private(set) var personNames: [String: String] = [:]
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var indexingTarget = 0

    private let analysisQueue = DispatchQueue(
        label: "com.jdarkyeka6.TideLibrary.vision",
        qos: .utility
    )

    private var workingPeople: [WorkingPerson] = []
    private var activeLibrarySignature = ""

    private let maxAssetsPerSession = 1000
    private let maxFacesPerPhoto = 3
    private let personDistanceThreshold: Float = 11.5
    private let personNamesKey = "TideLibrary.PersonNames.v1"

    init() {
        loadRecords()
        loadPersonNames()
    }

    var progress: Double {
        guard indexingTarget > 0 else { return 0 }
        return Double(indexedCount) / Double(indexingTarget)
    }

    func startIndexing(assets: [PhotoAssetRef]) {
        guard !assets.isEmpty else { return }

        // Photos can vend preview thumbnails for both image and video assets.
        // Indexing the video preview lets layered searches such as
        // "vids oct Jake" include videos whose poster frame contains Jake.
        let targetAssets = Array(assets.prefix(maxAssetsPerSession))
        let signature = "\(targetAssets.first?.id ?? "none"):\(targetAssets.count)"

        guard !isIndexing, activeLibrarySignature != signature else { return }

        activeLibrarySignature = signature
        isIndexing = true
        indexedCount = 0
        indexingTarget = targetAssets.count
        workingPeople.removeAll(keepingCapacity: true)
        people = []

        Task {
            for asset in targetAssets {
                if Task.isCancelled { break }

                guard let cgImage = await requestAnalysisImage(assetID: asset.id) else {
                    indexedCount += 1
                    continue
                }

                let needsSearchRecord = records[asset.id] == nil
                let payload = await analyze(
                    cgImage: cgImage,
                    assetID: asset.id,
                    includeSearch: needsSearchRecord
                )

                if let searchRecord = payload.searchRecord {
                    records[asset.id] = searchRecord
                }

                for face in payload.faces {
                    addFace(face, assetID: asset.id)
                }

                indexedCount += 1

                if indexedCount % 25 == 0 {
                    publishPeople()
                }

                if indexedCount % 75 == 0 {
                    saveRecords()
                    await Task.yield()
                }
            }

            publishPeople()
            saveRecords()
            isIndexing = false
        }
    }

    func displayName(for person: PersonCluster, fallbackIndex: Int? = nil) -> String {
        if let name = personNames[person.id],
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        if let fallbackIndex {
            return "Person \(fallbackIndex + 1)"
        }

        return "Unnamed person"
    }

    func setPersonName(_ rawName: String, for person: PersonCluster) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            personNames.removeValue(forKey: person.id)
        } else {
            personNames[person.id] = name
        }

        UserDefaults.standard.set(personNames, forKey: personNamesKey)
    }

    func searchAsync(
        assets: [PhotoAssetRef],
        query: String
    ) async -> [PhotoAssetRef] {
        let recordSnapshot = records
        let peopleSnapshot = people
        let nameSnapshot = personNames

        return await Task.detached(priority: .userInitiated) {
            Self.filterAssets(
                assets,
                query: query,
                records: recordSnapshot,
                people: peopleSnapshot,
                personNames: nameSnapshot
            )
        }.value
    }

    func assets(
        for person: PersonCluster,
        in library: [PhotoAssetRef]
    ) -> [PhotoAssetRef] {
        let ids = Set(person.assetIDs)
        return library.filter { ids.contains($0.id) }
    }

    private static func filterAssets(
        _ assets: [PhotoAssetRef],
        query: String,
        records: [String: SmartSearchRecord],
        people: [PersonCluster],
        personNames: [String: String]
    ) -> [PhotoAssetRef] {
        let rawTerms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !rawTerms.isEmpty else { return [] }

        let videoTerms: Set<String> = [
            "vid", "vids", "video", "videos", "movie", "movies", "clip", "clips"
        ]

        let photoTerms: Set<String> = [
            "photo", "photos", "pic", "pics", "picture", "pictures", "image", "images"
        ]

        let monthAliases: [String: Int] = [
            "jan": 1, "january": 1,
            "feb": 2, "february": 2,
            "mar": 3, "march": 3,
            "apr": 4, "april": 4,
            "may": 5,
            "jun": 6, "june": 6,
            "jul": 7, "july": 7,
            "aug": 8, "august": 8,
            "sep": 9, "sept": 9, "september": 9,
            "oct": 10, "october": 10,
            "nov": 11, "november": 11,
            "dec": 12, "december": 12
        ]

        var requireVideo: Bool?
        var requiredMonth: Int?
        var requiredYear: Int?
        var textTerms: [String] = []
        var requiredPersonSets: [Set<String>] = []

        let namedPeople: [(tokens: Set<String>, assetIDs: Set<String>)] = people.compactMap { person in
            guard let rawName = personNames[person.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else {
                return nil
            }

            let tokens = Set(
                rawName
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
                    .map(String.init)
            )

            guard !tokens.isEmpty else { return nil }
            return (tokens, Set(person.assetIDs))
        }

        for term in rawTerms {
            if videoTerms.contains(term) {
                requireVideo = true
                continue
            }

            if photoTerms.contains(term) {
                requireVideo = false
                continue
            }

            if let month = monthAliases[term] {
                requiredMonth = month
                continue
            }

            if term.count == 4,
               let year = Int(term),
               (1900...2200).contains(year) {
                requiredYear = year
                continue
            }

            let matchingPersonSets = namedPeople
                .filter { $0.tokens.contains(term) }
                .map(\.assetIDs)

            if !matchingPersonSets.isEmpty {
                let combined = matchingPersonSets.reduce(into: Set<String>()) {
                    $0.formUnion($1)
                }
                requiredPersonSets.append(combined)
                continue
            }

            textTerms.append(term)
        }

        let calendar = Calendar.current

        return assets.filter { asset in
            if let requireVideo, asset.isVideo != requireVideo {
                return false
            }

            if let requiredMonth,
               calendar.component(.month, from: asset.createdAt) != requiredMonth {
                return false
            }

            if let requiredYear,
               calendar.component(.year, from: asset.createdAt) != requiredYear {
                return false
            }

            for personIDs in requiredPersonSets {
                if !personIDs.contains(asset.id) {
                    return false
                }
            }

            if textTerms.isEmpty {
                return true
            }

            var haystack = asset.searchableText

            if let record = records[asset.id] {
                haystack += " " + record.searchableText

                if record.faceCount > 0 {
                    haystack += " person people face faces portrait"
                }

                if !record.recognizedText.isEmpty {
                    haystack += " text words document receipt sign screenshot"
                }
            }

            return textTerms.allSatisfy {
                haystack.localizedCaseInsensitiveContains($0)
            }
        }
    }

    private func publishPeople() {
        people = workingPeople
            .filter { $0.assetIDs.count >= 2 }
            .map {
                PersonCluster(
                    id: $0.id,
                    representativeAssetID: $0.representativeAssetID,
                    representativeFaceBounds: $0.representativeFaceBounds,
                    assetIDs: Array($0.assetIDs)
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.id < $1.id
                }
                return $0.count > $1.count
            }
    }

    private func addFace(_ face: DetectedFace, assetID: String) {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude

        for index in workingPeople.indices {
            var distance: Float = 0

            do {
                try face.feature.computeDistance(
                    &distance,
                    to: workingPeople[index].representativeFeature
                )
            } catch {
                continue
            }

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        if let bestIndex, bestDistance <= personDistanceThreshold {
            workingPeople[bestIndex].assetIDs.insert(assetID)
        } else {
            workingPeople.append(
                WorkingPerson(
                    id: Self.stablePersonID(
                        assetID: assetID,
                        bounds: face.bounds
                    ),
                    representativeAssetID: assetID,
                    representativeFaceBounds: face.bounds,
                    representativeFeature: face.feature,
                    assetIDs: [assetID]
                )
            )
        }
    }

    private static func stablePersonID(
        assetID: String,
        bounds: FaceBounds
    ) -> String {
        func rounded(_ value: Double) -> String {
            String(format: "%.3f", value)
        }

        return [
            assetID,
            rounded(bounds.x),
            rounded(bounds.y),
            rounded(bounds.width),
            rounded(bounds.height)
        ].joined(separator: "|")
    }

    private func requestAnalysisImage(assetID: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var completed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !completed else { return }

                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error

                if cancelled || error != nil {
                    completed = true
                    continuation.resume(returning: nil)
                    return
                }

                guard !degraded else { return }

                completed = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    private func analyze(
        cgImage: CGImage,
        assetID: String,
        includeSearch: Bool
    ) async -> AnalysisPayload {
        await withCheckedContinuation { continuation in
            analysisQueue.async {
                let faceRequest = VNDetectFaceRectanglesRequest()
                faceRequest.preferBackgroundProcessing = true

                var requests: [VNRequest] = [faceRequest]
                var classifyRequest: VNClassifyImageRequest?
                var textRequest: VNRecognizeTextRequest?

                if includeSearch {
                    let classify = VNClassifyImageRequest()
                    classify.preferBackgroundProcessing = true
                    classifyRequest = classify
                    requests.append(classify)

                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .fast
                    text.usesLanguageCorrection = false
                    text.preferBackgroundProcessing = true
                    textRequest = text
                    requests.append(text)
                }

                do {
                    try VNImageRequestHandler(
                        cgImage: cgImage,
                        options: [:]
                    ).perform(requests)
                } catch {
                    continuation.resume(
                        returning: AnalysisPayload(
                            searchRecord: includeSearch
                                ? SmartSearchRecord(
                                    assetID: assetID,
                                    labels: [],
                                    recognizedText: "",
                                    faceCount: 0
                                )
                                : nil,
                            faces: []
                        )
                    )
                    return
                }

                let faceObservations = (faceRequest.results ?? [])
                    .filter {
                        $0.boundingBox.width * $0.boundingBox.height >= 0.012
                    }
                    .sorted {
                        ($0.boundingBox.width * $0.boundingBox.height) >
                        ($1.boundingBox.width * $1.boundingBox.height)
                    }

                var detectedFaces: [DetectedFace] = []

                for observation in faceObservations.prefix(self.maxFacesPerPhoto) {
                    guard let crop = Self.cropFace(
                        from: cgImage,
                        normalizedBounds: observation.boundingBox
                    ) else {
                        continue
                    }

                    let featureRequest = VNGenerateImageFeaturePrintRequest()
                    featureRequest.imageCropAndScaleOption = .scaleFill
                    featureRequest.preferBackgroundProcessing = true

                    do {
                        try VNImageRequestHandler(
                            cgImage: crop,
                            options: [:]
                        ).perform([featureRequest])

                        if let feature = featureRequest.results?.first {
                            detectedFaces.append(
                                DetectedFace(
                                    bounds: FaceBounds(observation.boundingBox),
                                    feature: feature
                                )
                            )
                        }
                    } catch {
                        continue
                    }
                }

                var searchRecord: SmartSearchRecord?

                if includeSearch {
                    let labels = (classifyRequest?.results ?? [])
                        .filter { $0.confidence >= 0.08 }
                        .prefix(14)
                        .map {
                            $0.identifier
                                .replacingOccurrences(of: "_", with: " ")
                                .replacingOccurrences(of: "-", with: " ")
                                .lowercased()
                        }

                    let recognizedLines = (textRequest?.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .prefix(24)

                    searchRecord = SmartSearchRecord(
                        assetID: assetID,
                        labels: Array(labels),
                        recognizedText: recognizedLines.joined(separator: " "),
                        faceCount: faceObservations.count
                    )
                }

                continuation.resume(
                    returning: AnalysisPayload(
                        searchRecord: searchRecord,
                        faces: detectedFaces
                    )
                )
            }
        }
    }

    private static func cropFace(
        from image: CGImage,
        normalizedBounds: CGRect
    ) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        var rect = CGRect(
            x: normalizedBounds.minX * width,
            y: (1 - normalizedBounds.maxY) * height,
            width: normalizedBounds.width * width,
            height: normalizedBounds.height * height
        )

        let paddingX = rect.width * 0.16
        let paddingY = rect.height * 0.20
        rect = rect.insetBy(dx: -paddingX, dy: -paddingY)

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        rect = rect.intersection(imageRect).integral

        guard rect.width >= 40, rect.height >= 40 else { return nil }
        return image.cropping(to: rect)
    }

    private var indexURL: URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            let folder = base.appendingPathComponent(
                "TideLibrary",
                isDirectory: true
            )

            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
            }

            return folder.appendingPathComponent("search-index-v1.json")
        } catch {
            return nil
        }
    }

    private func loadRecords() {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(
                [SmartSearchRecord].self,
                from: data
              ) else {
            return
        }

        records = Dictionary(
            uniqueKeysWithValues: decoded.map { ($0.assetID, $0) }
        )
    }

    private func saveRecords() {
        guard let url = indexURL else { return }

        let values = Array(records.values)
        guard let data = try? JSONEncoder().encode(values) else { return }

        try? data.write(to: url, options: .atomic)
    }

    private func loadPersonNames() {
        guard let stored = UserDefaults.standard.dictionary(
            forKey: personNamesKey
        ) as? [String: String] else {
            return
        }

        personNames = stored
    }
}

private struct AnalysisPayload {
    let searchRecord: SmartSearchRecord?
    let faces: [DetectedFace]
}

private struct DetectedFace {
    let bounds: FaceBounds
    let feature: VNFeaturePrintObservation
}

private struct WorkingPerson {
    let id: String
    let representativeAssetID: String
    let representativeFaceBounds: FaceBounds
    let representativeFeature: VNFeaturePrintObservation
    var assetIDs: Set<String>
}
