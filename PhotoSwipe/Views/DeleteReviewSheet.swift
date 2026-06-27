import SwiftUI

/// Grid of every asset currently marked for deletion. Tapping a thumbnail
/// toggles whether it will be included in the batch delete; long-pressing
/// reveals a full preview via the system context menu. Tap edits update the
/// store directly, so closing without confirming leaves the user's edits in
/// place for next time.
struct DeleteReviewSheet: View {
    let service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    let onConfirm: () async -> Bool

    @State private var pendingAssets: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss

    /// Fixed 3-column grid (Photos.app-style). Square cells crop to fill,
    /// preserving a calm uniform layout regardless of original aspect ratio.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    confirmBar
                }
        }
        .task {
            await reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pendingAssets.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(pendingAssets) { asset in
                        ThumbnailCell(
                            asset: asset,
                            service: service,
                            isSelected: store.markedForDeletionIDs.contains(asset.id)
                        ) {
                            toggle(asset.id)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(.largeTitle))
                .foregroundStyle(.secondary)
            Text("Nothing marked for deletion")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task {
                    isDeleting = true
                    let success = await onConfirm()
                    isDeleting = false
                    if success { dismiss() }
                }
            } label: {
                HStack(spacing: 8) {
                    if isDeleting {
                        ProgressView().tint(.white)
                    }
                    Text("Delete permanently (\(store.markedForDeletionIDs.count))")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(store.markedForDeletionIDs.isEmpty || isDeleting)
            .padding(16)
        }
        .background(.bar)
    }

    private func toggle(_ id: String) {
        if store.markedForDeletionIDs.contains(id) {
            store.spare(id)
        } else {
            store.markForDeletion(id)
        }
    }

    private func reload() async {
        isLoading = true
        pendingAssets = await service.fetchAssets(withIDs: store.markedForDeletionIDs)
        isLoading = false
    }
}

private struct ThumbnailCell: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService
    let isSelected: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            // Color drives the layout (it's flexible and accepts any
            // proposed size). The image floats inside via .overlay and is
            // clipped before the rounded corner is applied, so portrait /
            // landscape originals never push past the square cell bounds.
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipped()
                .overlay {
                    if !isSelected {
                        Color.black.opacity(0.45)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? .red : .white.opacity(0.35))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.formattedDate)
        .accessibilityValue(isSelected ? "Will be deleted" : "Spared")
        .contextMenu {
            Button(
                isSelected ? "Spare from deletion" : "Mark for deletion",
                systemImage: isSelected ? "arrow.uturn.backward" : "trash"
            ) {
                onTap()
            }
        } preview: {
            ThumbnailPreview(asset: asset, service: service)
        }
        .task(id: asset.id) {
            image = nil
            for await next in service.imageStream(
                for: asset,
                targetSize: CGSize(width: 320, height: 320)
            ) {
                image = next
            }
        }
    }
}

/// Full-size preview shown when long-pressing a thumbnail. Loads a larger
/// image than the grid cell so the user can actually see what they're about
/// to delete.
private struct ThumbnailPreview: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 280, height: 280)
            }
        }
        .task(id: asset.id) {
            for await next in service.imageStream(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1200)
            ) {
                image = next
            }
        }
    }
}
