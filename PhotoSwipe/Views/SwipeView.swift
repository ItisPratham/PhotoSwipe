import SwiftUI

/// Hosts the swipe deck. For Milestone 3 it loads the library and renders the
/// first asset as a static card — gestures, persistence, and the delete flow
/// arrive in later milestones.
struct SwipeView: View {
    @ObservedObject var service: PhotoLibraryService

    @State private var assets: [PhotoAsset] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading library…")
                    .controlSize(.large)
            } else if let first = assets.first {
                CardView(asset: first, service: service)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            assets = await service.fetchAllImages()
            isLoading = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No photos to review")
                .font(.headline)
        }
        .foregroundStyle(.secondary)
    }
}
