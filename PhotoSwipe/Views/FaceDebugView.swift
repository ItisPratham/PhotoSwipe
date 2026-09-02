import Photos
import SwiftUI
import UIKit
import Vision

/// TEMPORARY diagnostic. Samples the library, aligns + embeds each face with the
/// real pipeline, then groups the crops by the model's own embeddings and shows
/// the groups. If the same person's crops land together → embeddings are good
/// (any trouble is threshold/clustering). If one person scatters across many
/// groups → the model input (channel order / scaling) is wrong. Remove before
/// shipping.
struct FaceDebugView: View {
    let service: PhotoLibraryService
    @StateObject private var model = FaceDebugModel()

    var body: some View {
        ScrollView {
            if model.isRunning {
                ProgressView("Embedding sample…").padding()
            }
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Face \(index + 1) — \(group.images.count) photo\(group.images.count == 1 ? "" : "s")")
                            .font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(group.images.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .interpolation(.none)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Face grouping debug")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.run(using: service) }
    }
}

/// Backs the debug grid. Kept in-file — throwaway diagnostic screen.
@MainActor
private final class FaceDebugModel: ObservableObject {
    struct Group: Identifiable {
        let id = UUID().uuidString
        let images: [UIImage]
    }

    @Published var groups: [Group] = []
    @Published var isRunning = false
    @Published var status = ""

    func run(using service: PhotoLibraryService) async {
        guard groups.isEmpty, !isRunning else { return }
        isRunning = true
        status = "Sampling and embedding faces…"
        let assets = await service.fetchImages(source: DeckSource(scope: .allPhotos, media: .photos))
        let sample = Array(assets.prefix(300))
        let result = await Task.detached(priority: .userInitiated) {
            FaceDebugModel.buildGroups(assets: sample, faceLimit: 150)
        }.value
        groups = result.groups.map { Group(images: $0.map(UIImage.init(cgImage:))) }
        status = "\(result.faceCount) faces → \(groups.count) unique people "
            + "(threshold \(String(format: "%.2f", FaceClusterer.defaultThreshold))). "
            + "The same person's crops should sit in one group."
        isRunning = false
    }

    /// Aligns + embeds a sample, then clusters by embedding. Returns crop groups
    /// (biggest first) and the total face count.
    private nonisolated static func buildGroups(assets: [PhotoAsset],
                                                faceLimit: Int) -> (groups: [[CGImage]], faceCount: Int) {
        var crops: [CGImage] = []
        var embeddings: [[Float]] = []

        for asset in assets {
            if crops.count >= faceLimit { break }
            autoreleasepool {
                guard let cg = thumbnail(for: asset.phAsset) else { return }
                let request = VNDetectFaceLandmarksRequest()
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                guard let results = request.results else { return }
                let size = CGSize(width: cg.width, height: cg.height)
                for observation in results where observation.boundingBox.width >= 0.05 {
                    if crops.count >= faceLimit { break }
                    guard let array = FaceAligner.alignedMultiArray(
                            cgImage: cg, imageSize: size, observation: observation),
                          let embedding = FaceEmbedder.shared.embed(array),
                          let crop = FaceAligner.debugAlignedCGImage(
                            cgImage: cg, imageSize: size, observation: observation)
                    else { continue }
                    crops.append(crop)
                    embeddings.append(embedding)
                }
            }
        }

        let observations = embeddings.enumerated().map { offset, embedding in
            FaceObservation(localIdentifier: String(offset), faceIndex: 0,
                            embedding: embedding, quality: 1,
                            boundingBox: .zero, personID: nil)
        }
        let result = FaceClusterer().cluster(newFaces: observations, existing: [])

        var byPerson: [String: [Int]] = [:]
        for (faceID, personID) in result.assignments {
            if let indexPart = faceID.split(separator: "#").first,
               let index = Int(indexPart) {
                byPerson[personID, default: []].append(index)
            }
        }
        let groups = byPerson.values
            .map { indices in indices.sorted().map { crops[$0] } }
            .sorted { $0.count > $1.count }
        return (groups, crops.count)
    }

    private nonisolated static func thumbnail(for asset: PHAsset) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        var result: CGImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1024, height: 1024),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            result = image?.cgImage
        }
        return result
    }
}
