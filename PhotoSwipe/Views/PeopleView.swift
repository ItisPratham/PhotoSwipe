import SwiftUI

/// The People tab. Empty until the user runs the opt-in, on-device face scan;
/// then a grid of person clusters (cover + count). Tapping a person pushes
/// `PersonDetailView`. The person-detail and deck destinations are registered
/// on the tab's stack in `AppTabView`.
struct PeopleView: View {
    @ObservedObject var service: PhotoLibraryService
    @StateObject private var viewModel = PeopleViewModel()

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 3
    )

    var body: some View {
        content
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reloadButton }
            .task { viewModel.onAppear(using: service) }
            .onChange(of: service.libraryVersion) { _, _ in
                viewModel.onLibraryChange(using: service)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .unavailable: unavailableState
        case .idle: explainer
        case .scanning: scanningState
        case .clustering: clusteringState
        case .empty: emptyState
        case .results: grid
        }
    }

    // MARK: - States

    private var explainer: some View {
        ContentUnavailableView {
            Label("Find people", systemImage: "person.2")
        } description: {
            Text("Group your photos by the people in them. This may take a few minutes and runs entirely on your device — nothing leaves your phone.")
        } actions: {
            Button("Scan library") { viewModel.startFirstScan(using: service) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 20) {
            ProgressView(value: viewModel.progress) {
                Text("Scanning faces…")
            } currentValueLabel: {
                Text("\(viewModel.processed) of \(viewModel.total)")
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            Button("Cancel") { viewModel.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clusteringState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Grouping faces…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No people found", systemImage: "person.slash")
        } description: {
            Text("The scan didn't find recognizable faces. Add more photos and scan again.")
        } actions: {
            Button("Scan again") { viewModel.reload(using: service) }
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("Face model not installed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The on-device face model isn't bundled in this build, so people grouping is unavailable.")
        }
    }

    private var grid: some View {
        ScrollView {
            peopleHeader
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.clusters) { cluster in
                    NavigationLink(value: cluster) {
                        PersonCell(cluster: cluster, service: service)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var peopleHeader: some View {
        HStack {
            Text("\(viewModel.clusters.count) people")
                .font(.headline)
            Spacer()
            if viewModel.isRefreshing {
                ProgressView()
            }
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.top, 8)
    }

    @ToolbarContentBuilder
    private var reloadButton: some ToolbarContent {
        if viewModel.phase == .results {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.reload(using: service)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityLabel("Rescan for people")
                }
                .disabled(viewModel.isRefreshing)
            }
        }
    }
}

/// One person in the grid: a circular cover with the name and photo count.
private struct PersonCell: View {
    let cluster: PersonCluster
    let service: PhotoLibraryService

    var body: some View {
        VStack(spacing: 6) {
            PersonCoverView(assetID: cluster.coverAssetID, service: service)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(Circle())

            Text(cluster.displayName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(cluster.photoCount) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.displayName), \(cluster.photoCount) photos")
    }
}

/// Resolves a cover asset id to a thumbnail. Kept private to People — a small
/// helper tightly bound to the grid.
private struct PersonCoverView: View {
    let assetID: String?
    let service: PhotoLibraryService

    @State private var asset: PhotoAsset?

    var body: some View {
        Group {
            if let asset {
                Thumbnail(asset: asset, service: service)
            } else {
                Theme.cardSurface
            }
        }
        .task(id: assetID) {
            guard let assetID else { return }
            asset = await service.fetchAssets(withIDs: [assetID]).first
        }
    }
}
