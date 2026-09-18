import Foundation
import Photos
import UIKit
import Vision

private let tideFaceNetEngine = FaceNetEmbeddingEngine()

private struct PersistedIndexState: Codable {
    var knownAssetIDs: [String]
    var seededInitialLibrary: Bool
    var peopleEngineVersion: Int?
}

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
    private var storedClusters: [PersonCluster] = []
    private var knownAssetIDs = Set<String>()
    private var seededInitialLibrary = false
    private var peopleEngineVersion: Int?

    private let currentPeopleEngineVersion = 2
    private let initialIndexLimit = 1000
    private let incrementalIndexLimit = 500
    private let maxFacesPerPhoto = 8

    // FaceNet cosine thresholds. We require both a useful score and a gap
    // over the runner-up so two similar-looking people don't get fused.
    private let automaticMatchThreshold: Float = 0.58
    private let strongMatchThreshold: Float = 0.72
    private let runnerUpMargin: Float = 0.06
    private let minimumFaceQuality: Float = 0.18

    private let personNamesKey = "TideLibrary.PersonNames.v1"

    init() {
        loadRecords()
        loadPeople()
        loadIndexState()
        loadPersonNames()
    }

    var progress: Double {
        guard indexingTarget > 0 else { return 0 }
        return Double(indexedCount) / Double(indexingTarget)
    }

    func startIndexing(assets: [PhotoAssetRef]) {
        guard !assets.isEmpty, !isIndexing else { return }

        let currentIDs = Set(assets.map(\.id))
        pruneDeletedAssets(currentIDs: currentIDs)

        let needsPeopleRebuild =
            seededInitialLibrary &&
            (
                (peopleEngineVersion ?? 1) < currentPeopleEngineVersion ||
                storedClusters.contains { $0.centroidEmbedding == nil }
            )

        let oldNamedClusters: [PersonCluster]

        if needsPeopleRebuild {
            oldNamedClusters = storedClusters.filter {
                personNames[$0.id] != nil
            }

            // The old Vision feature-print clusters are intentionally discarded.
            // They were generic image-similarity groups, not face embeddings.
            storedClusters = []
            workingPeople = []
            people = []
        } else {
            oldNamedClusters = []
        }

        let targetAssets: [PhotoAssetRef]

        if needsPeopleRebuild {
            // One-time migration to FaceNet. Search/OCR records are reused.
            targetAssets = Array(assets.prefix(initialIndexLimit))
        } else if !seededInitialLibrary {
            targetAssets = Array(assets.prefix(initialIndexLimit))
        } else {
            let newAssets = assets.filter {
                !knownAssetIDs.contains($0.id)
            }
            targetAssets = Array(
                newAssets.prefix(incrementalIndexLimit)
            )
        }

        guard !targetAssets.isEmpty else {
            indexedCount = 0
            indexingTarget = 0
            return
        }

        isIndexing = true
        indexedCount = 0
        indexingTarget = targetAssets.count

        if !needsPeopleRebuild {
            workingPeople = storedClusters.compactMap {
                guard
                    let centroid = $0.centroidEmbedding,
                    !centroid.isEmpty
                else {
                    return nil
                }

                return WorkingPerson(
                    id: $0.id,
                    representativeAssetID:
                        $0.representativeAssetID,
                    representativeFaceBounds:
                        $0.representativeFaceBounds,
                    representativeQuality:
                        $0.representativeQuality ?? 0,
                    centroidEmbedding: centroid,
                    embeddingSampleCount:
                        max($0.embeddingSampleCount ?? 1, 1),
                    assetIDs: Set($0.assetIDs)
                )
            }
        }

        Task {
            for asset in targetAssets {
                if Task.isCancelled { break }

                guard
                    let cgImage = await requestAnalysisImage(
                        assetID: asset.id
                    )
                else {
                    indexedCount += 1

                    if seededInitialLibrary && !needsPeopleRebuild {
                        knownAssetIDs.insert(asset.id)
                    }

                    continue
                }

                let needsSearchRecord =
                    records[asset.id] == nil

                let payload = await analyze(
                    cgImage: cgImage,
                    assetID: asset.id,
                    includeSearch: needsSearchRecord
                )

                if let searchRecord = payload.searchRecord {
                    records[asset.id] = searchRecord
                }

                for face in payload.faces {
                    addFace(
                        face,
                        assetID: asset.id
                    )
                }

                indexedCount += 1

                if seededInitialLibrary && !needsPeopleRebuild {
                    knownAssetIDs.insert(asset.id)
                }

                if indexedCount % 20 == 0 {
                    publishPeople()
                }

                if indexedCount % 50 == 0 {
                    saveRecords()
                    savePeople()
                    saveIndexState()
                    await Task.yield()
                }
            }

            publishPeople()

            if needsPeopleRebuild {
                migrateNames(
                    from: oldNamedClusters
                )
                peopleEngineVersion =
                    currentPeopleEngineVersion
            }

            if !seededInitialLibrary {
                seededInitialLibrary = true

                // Initial indexing is deliberately capped. Mark the current
                // library as the baseline so reopening doesn't churn through
                // the rest of a huge library automatically.
                knownAssetIDs = currentIDs
                peopleEngineVersion =
                    currentPeopleEngineVersion
            }

            saveRecords()
            savePeople()
            saveIndexState()
            savePersonNames()

            indexedCount = indexingTarget
            isIndexing = false
        }
    }

    func displayName(
        for person: PersonCluster,
        fallbackIndex: Int? = nil
    ) -> String {
        if let name = personNames[person.id],
           !name.trimmingCharacters(
                in: .whitespacesAndNewlines
           ).isEmpty {
            return name
        }

        if let fallbackIndex {
            return "Person \(fallbackIndex + 1)"
        }

        return "Unnamed person"
    }

    func setPersonName(
        _ rawName: String,
        for person: PersonCluster
    ) {
        let name = rawName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if name.isEmpty {
            personNames.removeValue(
                forKey: person.id
            )
        } else {
            personNames[person.id] = name
        }

        savePersonNames()
    }

    func searchAsync(
        assets: [PhotoAssetRef],
        query: String
    ) async -> [PhotoAssetRef] {
        let recordSnapshot = records
        let peopleSnapshot = people
        let nameSnapshot = personNames

        return await Task.detached(
            priority: .userInitiated
        ) {
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

        return library.filter {
            ids.contains($0.id)
        }
    }

    nonisolated private static func filterAssets(
        _ assets: [PhotoAssetRef],
        query: String,
        records: [String: SmartSearchRecord],
        people: [PersonCluster],
        personNames: [String: String]
    ) -> [PhotoAssetRef] {
        let rawTerms = query
            .lowercased()
            .split(
                whereSeparator: {
                    $0.isWhitespace || $0 == ","
                }
            )
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !rawTerms.isEmpty else { return [] }

        let videoTerms: Set<String> = [
            "vid", "vids", "video", "videos",
            "movie", "movies", "clip", "clips"
        ]

        let photoTerms: Set<String> = [
            "photo", "photos", "pic", "pics",
            "picture", "pictures", "image", "images"
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

        let namedPeople:
            [(tokens: Set<String>, assetIDs: Set<String>)] =
            people.compactMap { person in
                guard
                    let rawName = personNames[person.id]?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                    !rawName.isEmpty
                else {
                    return nil
                }

                let tokens = Set(
                    rawName
                        .lowercased()
                        .split(
                            whereSeparator: {
                                $0.isWhitespace ||
                                $0 == "-"
                            }
                        )
                        .map(String.init)
                )

                guard !tokens.isEmpty else {
                    return nil
                }

                return (
                    tokens,
                    Set(person.assetIDs)
                )
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

            let matchingPersonSets =
                namedPeople
                .filter {
                    $0.tokens.contains(term)
                }
                .map(\.assetIDs)

            if !matchingPersonSets.isEmpty {
                let combined =
                    matchingPersonSets.reduce(
                        into: Set<String>()
                    ) {
                        $0.formUnion($1)
                    }

                requiredPersonSets.append(
                    combined
                )
                continue
            }

            textTerms.append(term)
        }

        let calendar = Calendar.current

        return assets.filter { asset in
            if let requireVideo,
               asset.isVideo != requireVideo {
                return false
            }

            if let requiredMonth,
               calendar.component(
                    .month,
                    from: asset.createdAt
               ) != requiredMonth {
                return false
            }

            if let requiredYear,
               calendar.component(
                    .year,
                    from: asset.createdAt
               ) != requiredYear {
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

            var haystack =
                asset.searchableText

            if let record = records[asset.id] {
                haystack +=
                    " " + record.searchableText

                if record.faceCount > 0 {
                    haystack +=
                        " person people face faces portrait"
                }

                if !record.recognizedText.isEmpty {
                    haystack +=
                        " text words document receipt sign screenshot"
                }
            }

            return textTerms.allSatisfy {
                haystack
                    .localizedCaseInsensitiveContains($0)
            }
        }
    }

    private func pruneDeletedAssets(
        currentIDs: Set<String>
    ) {
        records = records.filter {
            currentIDs.contains($0.key)
        }

        storedClusters =
            storedClusters.compactMap { cluster in
                let remaining =
                    cluster.assetIDs.filter {
                        currentIDs.contains($0)
                    }

                guard
                    currentIDs.contains(
                        cluster.representativeAssetID
                    ),
                    !remaining.isEmpty
                else {
                    personNames.removeValue(
                        forKey: cluster.id
                    )
                    return nil
                }

                return PersonCluster(
                    id: cluster.id,
                    representativeAssetID:
                        cluster.representativeAssetID,
                    representativeFaceBounds:
                        cluster.representativeFaceBounds,
                    assetIDs: remaining,
                    centroidEmbedding:
                        cluster.centroidEmbedding,
                    embeddingSampleCount:
                        cluster.embeddingSampleCount,
                    representativeQuality:
                        cluster.representativeQuality
                )
            }

        people = storedClusters
            .filter { $0.count >= 2 }
            .sorted {
                if $0.count == $1.count {
                    return $0.id < $1.id
                }
                return $0.count > $1.count
            }

        knownAssetIDs.formIntersection(
            currentIDs
        )
    }

    private func publishPeople() {
        storedClusters =
            workingPeople.map {
                PersonCluster(
                    id: $0.id,
                    representativeAssetID:
                        $0.representativeAssetID,
                    representativeFaceBounds:
                        $0.representativeFaceBounds,
                    assetIDs:
                        Array($0.assetIDs),
                    centroidEmbedding:
                        $0.centroidEmbedding,
                    embeddingSampleCount:
                        $0.embeddingSampleCount,
                    representativeQuality:
                        $0.representativeQuality
                )
            }

        people = storedClusters
            .filter { $0.count >= 2 }
            .sorted {
                if $0.count == $1.count {
                    return $0.id < $1.id
                }
                return $0.count > $1.count
            }
    }

    private func addFace(
        _ face: DetectedFace,
        assetID: String
    ) {
        var bestIndex: Int?
        var bestScore: Float = -1
        var secondBestScore: Float = -1

        for index in workingPeople.indices {
            // Two different faces in the same photo cannot be the same
            // physical person instance, so don't let one image poison a group.
            if workingPeople[index]
                .assetIDs
                .contains(assetID) {
                continue
            }

            let score =
                FaceNetEmbeddingEngine
                .cosineSimilarity(
                    face.embedding,
                    workingPeople[index]
                        .centroidEmbedding
                )

            if score > bestScore {
                secondBestScore = bestScore
                bestScore = score
                bestIndex = index
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        let hasClearMargin =
            bestScore - secondBestScore >=
            runnerUpMargin

        let canAutoMatch =
            bestScore >= strongMatchThreshold ||
            (
                bestScore >= automaticMatchThreshold &&
                hasClearMargin
            )

        if let bestIndex,
           canAutoMatch {
            var person =
                workingPeople[bestIndex]

            person.centroidEmbedding =
                FaceNetEmbeddingEngine
                .updatedCentroid(
                    current:
                        person.centroidEmbedding,
                    currentCount:
                        person.embeddingSampleCount,
                    adding:
                        face.embedding
                )

            person.embeddingSampleCount += 1
            person.assetIDs.insert(assetID)

            if face.quality >
                person.representativeQuality {
                person.representativeAssetID =
                    assetID
                person.representativeFaceBounds =
                    face.bounds
                person.representativeQuality =
                    face.quality
            }

            workingPeople[bestIndex] = person
        } else {
            workingPeople.append(
                WorkingPerson(
                    id: Self.stablePersonID(
                        assetID: assetID,
                        bounds: face.bounds
                    ),
                    representativeAssetID:
                        assetID,
                    representativeFaceBounds:
                        face.bounds,
                    representativeQuality:
                        face.quality,
                    centroidEmbedding:
                        face.embedding,
                    embeddingSampleCount: 1,
                    assetIDs: [assetID]
                )
            )
        }
    }

    private func migrateNames(
        from oldClusters: [PersonCluster]
    ) {
        guard
            !oldClusters.isEmpty,
            !people.isEmpty
        else {
            return
        }

        var migrated: [String: String] = [:]

        for old in oldClusters {
            guard
                let oldName = personNames[old.id],
                !oldName.isEmpty
            else {
                continue
            }

            let oldIDs = Set(old.assetIDs)
            var bestNew: PersonCluster?
            var bestOverlap = 0

            for candidate in people {
                let overlap =
                    oldIDs.intersection(
                        Set(candidate.assetIDs)
                    ).count

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestNew = candidate
                }
            }

            guard
                let bestNew,
                bestOverlap >= 2
            else {
                continue
            }

            migrated[bestNew.id] = oldName
        }

        // Keep names that already target current clusters, plus migrated names.
        personNames = personNames.filter {
            nameEntry in
            people.contains {
                $0.id == nameEntry.key
            }
        }

        for (id, name) in migrated {
            personNames[id] = name
        }
    }

    private static func stablePersonID(
        assetID: String,
        bounds: FaceBounds
    ) -> String {
        func rounded(
            _ value: Double
        ) -> String {
            String(
                format: "%.3f",
                value
            )
        }

        return [
            assetID,
            rounded(bounds.x),
            rounded(bounds.y),
            rounded(bounds.width),
            rounded(bounds.height)
        ].joined(separator: "|")
    }

    private func requestAnalysisImage(
        assetID: String
    ) async -> CGImage? {
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers:
                    [assetID],
                options: nil
            ).firstObject
        else {
            return nil
        }

        let options =
            PHImageRequestOptions()
        options.deliveryMode =
            .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed =
            true

        return await withCheckedContinuation {
            continuation in

            var completed = false

            PHImageManager.default()
                .requestImage(
                    for: asset,
                    targetSize: CGSize(
                        width: 1024,
                        height: 1024
                    ),
                    contentMode: .aspectFit,
                    options: options
                ) {
                    image,
                    info in

                    guard !completed else {
                        return
                    }

                    let cancelled =
                        (
                            info?[
                                PHImageCancelledKey
                            ] as? Bool
                        ) ?? false

                    let degraded =
                        (
                            info?[
                                PHImageResultIsDegradedKey
                            ] as? Bool
                        ) ?? false

                    let error =
                        info?[
                            PHImageErrorKey
                        ] as? Error

                    if cancelled ||
                        error != nil {
                        completed = true
                        continuation.resume(
                            returning: nil
                        )
                        return
                    }

                    guard !degraded else {
                        return
                    }

                    completed = true
                    continuation.resume(
                        returning:
                            image?.cgImage
                    )
                }
        }
    }

    private func analyze(
        cgImage: CGImage,
        assetID: String,
        includeSearch: Bool
    ) async -> AnalysisPayload {
        await withCheckedContinuation {
            continuation in

            analysisQueue.async {
                let qualityRequest =
                    VNDetectFaceCaptureQualityRequest()
                qualityRequest
                    .preferBackgroundProcessing =
                    true

                var firstPass:
                    [VNRequest] = [
                        qualityRequest
                    ]

                var classifyRequest:
                    VNClassifyImageRequest?

                var textRequest:
                    VNRecognizeTextRequest?

                if includeSearch {
                    let classify =
                        VNClassifyImageRequest()
                    classify
                        .preferBackgroundProcessing =
                        true
                    classifyRequest =
                        classify
                    firstPass.append(
                        classify
                    )

                    let text =
                        VNRecognizeTextRequest()
                    text.recognitionLevel =
                        .fast
                    text.usesLanguageCorrection =
                        false
                    text.preferBackgroundProcessing =
                        true
                    textRequest = text
                    firstPass.append(text)
                }

                let handler =
                    VNImageRequestHandler(
                        cgImage: cgImage,
                        options: [:]
                    )

                do {
                    try handler.perform(
                        firstPass
                    )
                } catch {
                    continuation.resume(
                        returning:
                            AnalysisPayload(
                                searchRecord:
                                    includeSearch
                                    ? SmartSearchRecord(
                                        assetID:
                                            assetID,
                                        labels: [],
                                        recognizedText:
                                            "",
                                        faceCount:
                                            0
                                    )
                                    : nil,
                                faces: []
                            )
                    )
                    return
                }

                let qualityFaces =
                    (qualityRequest.results ?? [])
                    .filter { observation in
                        let area =
                            observation
                            .boundingBox
                            .width *
                            observation
                            .boundingBox
                            .height

                        let quality =
                            observation
                            .faceCaptureQuality?
                            .floatValue ??
                            0

                        return
                            area >= 0.0025 &&
                            quality >=
                                self.minimumFaceQuality
                    }
                    .sorted {
                        let q0 =
                            $0.faceCaptureQuality?
                            .floatValue ?? 0
                        let q1 =
                            $1.faceCaptureQuality?
                            .floatValue ?? 0

                        return q0 > q1
                    }

                let limitedFaces =
                    Array(
                        qualityFaces.prefix(
                            self.maxFacesPerPhoto
                        )
                    )

                var landmarkFaces:
                    [VNFaceObservation] = []

                if !limitedFaces.isEmpty {
                    let landmarks =
                        VNDetectFaceLandmarksRequest()

                    landmarks
                        .inputFaceObservations =
                        limitedFaces

                    landmarks
                        .preferBackgroundProcessing =
                        true

                    do {
                        try handler.perform(
                            [landmarks]
                        )
                        landmarkFaces =
                            landmarks.results ??
                            []
                    } catch {
                        landmarkFaces =
                            limitedFaces
                    }
                }

                var detectedFaces:
                    [DetectedFace] = []

                for index in
                    landmarkFaces.indices {
                    guard
                        index <
                        limitedFaces.count
                    else {
                        break
                    }

                    let observation =
                        landmarkFaces[index]

                    let quality =
                        limitedFaces[index]
                        .faceCaptureQuality?
                        .floatValue ??
                        0

                    guard
                        let aligned =
                            Self.alignedFace(
                                from: cgImage,
                                observation:
                                    observation
                            ),
                        let embedding =
                            tideFaceNetEngine
                            .embedding(
                                for: aligned
                            )
                    else {
                        continue
                    }

                    detectedFaces.append(
                        DetectedFace(
                            bounds:
                                FaceBounds(
                                    observation
                                    .boundingBox
                                ),
                            quality:
                                quality,
                            embedding:
                                embedding
                        )
                    )
                }

                var searchRecord:
                    SmartSearchRecord?

                if includeSearch {
                    let labels =
                        (
                            classifyRequest?
                            .results ?? []
                        )
                        .filter {
                            $0.confidence >=
                                0.08
                        }
                        .prefix(14)
                        .map {
                            $0.identifier
                                .replacingOccurrences(
                                    of: "_",
                                    with: " "
                                )
                                .replacingOccurrences(
                                    of: "-",
                                    with: " "
                                )
                                .lowercased()
                        }

                    let recognizedLines =
                        (
                            textRequest?
                            .results ?? []
                        )
                        .compactMap {
                            $0.topCandidates(1)
                                .first?
                                .string
                        }
                        .prefix(24)

                    searchRecord =
                        SmartSearchRecord(
                            assetID: assetID,
                            labels:
                                Array(labels),
                            recognizedText:
                                recognizedLines
                                .joined(
                                    separator:
                                        " "
                                ),
                            faceCount:
                                qualityFaces.count
                        )
                }

                continuation.resume(
                    returning:
                        AnalysisPayload(
                            searchRecord:
                                searchRecord,
                            faces:
                                detectedFaces
                        )
                )
            }
        }
    }

    private static func alignedFace(
        from image: CGImage,
        observation: VNFaceObservation
    ) -> CGImage? {
        let sourceImage =
            UIImage(cgImage: image)

        guard
            let landmarks =
                observation.landmarks,
            let leftRegion =
                landmarks.leftEye,
            let rightRegion =
                landmarks.rightEye,
            !leftRegion.normalizedPoints.isEmpty,
            !rightRegion.normalizedPoints.isEmpty
        else {
            return paddedFace(
                from: image,
                bounds:
                    observation.boundingBox
            )
        }

        func average(
            _ points: [CGPoint]
        ) -> CGPoint {
            let total =
                points.reduce(
                    CGPoint.zero
                ) {
                    CGPoint(
                        x: $0.x + $1.x,
                        y: $0.y + $1.y
                    )
                }

            let count =
                CGFloat(points.count)

            return CGPoint(
                x: total.x / count,
                y: total.y / count
            )
        }

        let leftLocal =
            average(
                leftRegion.normalizedPoints
            )

        let rightLocal =
            average(
                rightRegion.normalizedPoints
            )

        let box =
            observation.boundingBox

        func sourcePoint(
            _ local: CGPoint
        ) -> CGPoint {
            let normalizedX =
                box.minX +
                local.x * box.width

            let normalizedY =
                box.minY +
                local.y * box.height

            return CGPoint(
                x:
                    normalizedX *
                    CGFloat(image.width),
                y:
                    (
                        1 -
                        normalizedY
                    ) *
                    CGFloat(image.height)
            )
        }

        let left =
            sourcePoint(leftLocal)
        let right =
            sourcePoint(rightLocal)

        let dx =
            right.x - left.x
        let dy =
            right.y - left.y

        let sourceDistance =
            hypot(dx, dy)

        guard sourceDistance >= 8 else {
            return paddedFace(
                from: image,
                bounds: box
            )
        }

        let targetLeft =
            CGPoint(x: 50, y: 62)
        let targetRight =
            CGPoint(x: 110, y: 62)

        let targetMid =
            CGPoint(
                x:
                    (
                        targetLeft.x +
                        targetRight.x
                    ) / 2,
                y:
                    (
                        targetLeft.y +
                        targetRight.y
                    ) / 2
            )

        let sourceMid =
            CGPoint(
                x:
                    (
                        left.x +
                        right.x
                    ) / 2,
                y:
                    (
                        left.y +
                        right.y
                    ) / 2
            )

        let scale =
            hypot(
                targetRight.x -
                    targetLeft.x,
                targetRight.y -
                    targetLeft.y
            ) /
            sourceDistance

        let angle =
            atan2(dy, dx)

        let renderer =
            UIGraphicsImageRenderer(
                size: CGSize(
                    width:
                        FaceNetEmbeddingEngine
                        .inputSide,
                    height:
                        FaceNetEmbeddingEngine
                        .inputSide
                )
            )

        let result =
            renderer.image {
                context in

                let cg =
                    context.cgContext

                cg.translateBy(
                    x: targetMid.x,
                    y: targetMid.y
                )

                cg.rotate(
                    by: -angle
                )

                cg.scaleBy(
                    x: scale,
                    y: scale
                )

                cg.translateBy(
                    x: -sourceMid.x,
                    y: -sourceMid.y
                )

                sourceImage.draw(
                    at: .zero
                )
            }

        return result.cgImage
    }

    private static func paddedFace(
        from image: CGImage,
        bounds: CGRect
    ) -> CGImage? {
        let width =
            CGFloat(image.width)
        let height =
            CGFloat(image.height)

        var rect =
            CGRect(
                x:
                    bounds.minX *
                    width,
                y:
                    (
                        1 -
                        bounds.maxY
                    ) *
                    height,
                width:
                    bounds.width *
                    width,
                height:
                    bounds.height *
                    height
            )

        let side =
            max(
                rect.width,
                rect.height
            ) * 1.55

        rect =
            CGRect(
                x:
                    rect.midX -
                    side / 2,
                y:
                    rect.midY -
                    side * 0.48,
                width: side,
                height: side
            )

        let imageRect =
            CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )

        rect =
            rect
            .intersection(imageRect)
            .integral

        guard
            rect.width >= 48,
            rect.height >= 48,
            let cropped =
                image.cropping(
                    to: rect
                )
        else {
            return nil
        }

        return cropped
    }

    private var storageFolderURL:
        URL? {
        do {
            let base =
                try FileManager
                .default
                .url(
                    for:
                        .applicationSupportDirectory,
                    in:
                        .userDomainMask,
                    appropriateFor:
                        nil,
                    create:
                        true
                )

            let folder =
                base
                .appendingPathComponent(
                    "TideLibrary",
                    isDirectory:
                        true
                )

            if !FileManager
                .default
                .fileExists(
                    atPath:
                        folder.path
                ) {
                try FileManager
                    .default
                    .createDirectory(
                        at: folder,
                        withIntermediateDirectories:
                            true
                    )
            }

            return folder
        } catch {
            return nil
        }
    }

    private var indexURL: URL? {
        storageFolderURL?
            .appendingPathComponent(
                "search-index-v1.json"
            )
    }

    private var peopleURL: URL? {
        storageFolderURL?
            .appendingPathComponent(
                "people-index-v1.json"
            )
    }

    private var stateURL: URL? {
        storageFolderURL?
            .appendingPathComponent(
                "index-state-v1.json"
            )
    }

    private func loadRecords() {
        guard
            let url = indexURL,
            let data =
                try? Data(
                    contentsOf: url
                ),
            let decoded =
                try? JSONDecoder()
                .decode(
                    [
                        SmartSearchRecord
                    ].self,
                    from: data
                )
        else {
            return
        }

        records =
            Dictionary(
                uniqueKeysWithValues:
                    decoded.map {
                        (
                            $0.assetID,
                            $0
                        )
                    }
            )
    }

    private func saveRecords() {
        guard let url = indexURL else {
            return
        }

        let values =
            Array(records.values)

        guard
            let data =
                try? JSONEncoder()
                .encode(values)
        else {
            return
        }

        try? data.write(
            to: url,
            options: .atomic
        )
    }

    private func loadPeople() {
        guard
            let url = peopleURL,
            let data =
                try? Data(
                    contentsOf: url
                ),
            let decoded =
                try? JSONDecoder()
                .decode(
                    [PersonCluster].self,
                    from: data
                )
        else {
            return
        }

        storedClusters = decoded

        people = decoded
            .filter {
                $0.count >= 2
            }
            .sorted {
                $0.count >
                $1.count
            }
    }

    private func savePeople() {
        guard let url = peopleURL else {
            return
        }

        guard
            let data =
                try? JSONEncoder()
                .encode(
                    storedClusters
                )
        else {
            return
        }

        try? data.write(
            to: url,
            options: .atomic
        )
    }

    private func loadIndexState() {
        guard
            let url = stateURL,
            let data =
                try? Data(
                    contentsOf: url
                ),
            let decoded =
                try? JSONDecoder()
                .decode(
                    PersistedIndexState.self,
                    from: data
                )
        else {
            return
        }

        knownAssetIDs =
            Set(
                decoded
                .knownAssetIDs
            )

        seededInitialLibrary =
            decoded
            .seededInitialLibrary

        peopleEngineVersion =
            decoded
            .peopleEngineVersion
    }

    private func saveIndexState() {
        guard let url = stateURL else {
            return
        }

        let state =
            PersistedIndexState(
                knownAssetIDs:
                    Array(
                        knownAssetIDs
                    ),
                seededInitialLibrary:
                    seededInitialLibrary,
                peopleEngineVersion:
                    peopleEngineVersion
            )

        guard
            let data =
                try? JSONEncoder()
                .encode(state)
        else {
            return
        }

        try? data.write(
            to: url,
            options: .atomic
        )
    }

    private func loadPersonNames() {
        guard
            let stored =
                UserDefaults
                .standard
                .dictionary(
                    forKey:
                        personNamesKey
                )
                as? [
                    String:
                    String
                ]
        else {
            return
        }

        personNames = stored
    }

    private func savePersonNames() {
        UserDefaults
            .standard
            .set(
                personNames,
                forKey:
                    personNamesKey
            )
    }
}

private struct AnalysisPayload {
    let searchRecord:
        SmartSearchRecord?
    let faces:
        [DetectedFace]
}

private struct DetectedFace {
    let bounds: FaceBounds
    let quality: Float
    let embedding: [Float]
}

private struct WorkingPerson {
    let id: String
    var representativeAssetID: String
    var representativeFaceBounds: FaceBounds
    var representativeQuality: Float
    var centroidEmbedding: [Float]
    var embeddingSampleCount: Int
    var assetIDs: Set<String>
}
