import SwiftUI

/// The People tab. Empty until the user runs the opt-in, on-device face scan;
/// then a grid of person clusters (cover + count). Tapping a person pushes
/// `PersonDetailView`. The person-detail and deck destinations are registered
/// on the tab's stack in `AppTabView`.
struct PeopleView: View {
    @ObservedObject var service: PhotoLibraryService
    @StateObject private var viewModel = PeopleViewModel()

    /// Grouping strength, 1 (stricter → more, smaller clusters) … 10 (looser →
    /// merges the same person across poses/lighting). Persisted per install.
    @AppStorage("PhotoSwipe.peopleSensitivity") private var sensitivity: Double = 1
    @AppStorage("PhotoSwipe.groupingExpanded") private var groupingExpanded: Bool = false
    @State private var showHidden = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 3
    )

    /// Maps the 1…10 slider to a cosine floor: 1 → 0.69 (strict), 10 → 0.42
    /// (loose). Higher sensitivity = lower floor = more merging.
    private func threshold(for s: Double) -> Float { Float(0.69 - (s - 1) * 0.03) }

    var body: some View {
        content
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reloadButton }
            .task {
                viewModel.similarityThreshold = threshold(for: sensitivity)
                viewModel.onAppear(using: service)
            }
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

    // Header and hidden-people row live outside the ScrollView so the grid's
    // NavigationLink tap areas can't bleed up into the controls above.
    private var grid: some View {
        VStack(spacing: 0) {
            peopleHeader
            hiddenSection
            ScrollView {
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
        .navigationDestination(isPresented: $showHidden) {
            HiddenPeopleView(viewModel: viewModel, service: service)
        }
    }

    /// Section row for hidden people. Uses a plain Button so the tap area is
    /// bounded to the explicit row height and can't bleed into the grid below.
    @ViewBuilder
    private var hiddenSection: some View {
        if !viewModel.hiddenClusters.isEmpty {
            Button { showHidden = true } label: {
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text("Hidden people")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(viewModel.hiddenClusters.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            Divider()
                .padding(.horizontal, Theme.Spacing.screenMargin)
        }
    }

    /// People count + inline grouping-strength toggle. The slider expands below
    /// when tapped so it doesn't clutter the grid by default.
    private var peopleHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(viewModel.clusters.count) people")
                    .font(.headline)
                if viewModel.isRefreshing {
                    ProgressView().scaleEffect(0.75)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { groupingExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(sensitivity >= 7 ? "Looser" : sensitivity <= 3 ? "Stricter" : "Balanced")
                            .font(.caption)
                        Image(systemName: groupingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRefreshing)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.top, 8)
            .padding(.bottom, groupingExpanded ? 2 : 6)

            if groupingExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.badge.plus").foregroundStyle(.secondary)
                        Slider(value: $sensitivity, in: 1...10, step: 1)
                            .accessibilityLabel("Grouping strength")
                            .accessibilityValue("\(Int(sensitivity)) of 10")
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
                    }
                    Text("Higher merges the same person across poses & lighting. Re-groups everyone — clears any names you've set.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .padding(.bottom, 8)
                .disabled(viewModel.isRefreshing)
                .onChange(of: sensitivity) { _, s in
                    viewModel.regroup(threshold: threshold(for: s))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

/// Lists hidden people so they can be restored. Reuses `PersonCoverView` from
/// this file. Updates live as the shared view model reloads on unhide.
private struct HiddenPeopleView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let service: PhotoLibraryService

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        Group {
            if viewModel.hiddenClusters.isEmpty {
                ContentUnavailableView("No hidden people", systemImage: "eye")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.hiddenClusters) { cluster in
                            VStack(spacing: 6) {
                                PersonCoverView(assetID: cluster.coverAssetID, service: service)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(Circle())
                                    .opacity(0.55)
                                Text(cluster.displayName)
                                    .font(.caption).lineLimit(1)
                                Button("Unhide") { viewModel.unhide(cluster.personID) }
                                    .font(.caption2)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Hidden people")
        .navigationBarTitleDisplayMode(.inline)
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
