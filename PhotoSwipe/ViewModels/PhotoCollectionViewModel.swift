import Foundation
import SwiftUI

/// Loads and orders a Browse-first asset collection. Ordinary collections
/// reuse PhotoKit's chronological fetch; Biggest files tops up the shared size
/// cache before sorting so opening its deck does not repeat the measurement.
@MainActor
final class PhotoCollectionViewModel: ObservableObject {
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var isLoading = true
    @Published private(set) var measuredCount = 0
    @Published private(set) var measureTotal = 0
    @Published private(set) var errorMessage: String?

    let collection: PhotoCollection

    private var loadedLibraryVersion: Int?
    private var positionByID: [String: Int] = [:]

    init(collection: PhotoCollection) {
        self.collection = collection
    }

    var count: Int { assets.count }

    var itemDescription: String {
        "\(count) \(count == 1 ? collection.singularItem : collection.pluralItem)"
    }

    func loadIfNeeded(using service: PhotoLibraryService, sizes: SizeStore) async {
        guard loadedLibraryVersion != service.libraryVersion else { return }
        let version = service.libraryVersion
        if assets.isEmpty { isLoading = true }
        errorMessage = nil

        var fetched = await service.fetchImages(source: collection.source)
        if collection.needsSizeOrdering {
            do {
                fetched = try await largestFirst(fetched, using: service, sizes: sizes)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "The file sizes couldn't be loaded. Please try again."
                isLoading = false
                return
            }
        }
        guard !Task.isCancelled else { return }

        assets = fetched
        positionByID = Dictionary(
            fetched.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        loadedLibraryVersion = version
        isLoading = false
    }

    func index(of id: String) -> Int? {
        positionByID[id]
    }

    func deckSource(startingAt asset: PhotoAsset? = nil) -> DeckSource {
        let ids = assets.map(\.id)
        guard let asset, let index = positionByID[asset.id] else {
            return .selection(ids)
        }
        return .selection(Array(ids[index...]))
    }

    private func largestFirst(
        _ fetched: [PhotoAsset],
        using service: PhotoLibraryService,
        sizes: SizeStore
    ) async throws -> [PhotoAsset] {
        await sizes.waitUntilLoaded()
        var missing = fetched.filter { sizes.size(for: $0.id) == nil }
        if !missing.isEmpty {
            await sizes.adoptIndexedSizes()
            missing = missing.filter { sizes.size(for: $0.id) == nil }
        }
        if !missing.isEmpty {
            measuredCount = 0
            measureTotal = missing.count
            defer {
                measureTotal = 0
                measuredCount = 0
            }
            let measured = try await service.byteSizes(for: missing) { done, _ in
                Task { @MainActor [weak self] in
                    self?.measuredCount = max(self?.measuredCount ?? 0, done)
                }
            }
            sizes.merge(measured)
        }
        return fetched.sorted {
            (sizes.size(for: $0.id) ?? 0) > (sizes.size(for: $1.id) ?? 0)
        }
    }
}
