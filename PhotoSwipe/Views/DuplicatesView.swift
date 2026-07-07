import SwiftUI

/// Opt-in near-duplicate finder. Warns before the first scan, shows determinate
/// progress with a Cancel, and lists the groups it finds. Tapping a group opens
/// the swipe deck scoped to it, with the suggested keeper badged. The scan runs
/// entirely on-device.
///
/// Once scanned, the screen auto-refreshes: opening it again, or any library
/// change (add / delete / capture) while it's open, re-runs the incremental
/// scan. A manual reload button is also offered. A Sensitivity slider tunes how
/// aggressively shots are grouped — changing it only re-groups (no rescan).
struct DuplicatesView: View {
    @ObservedObject var service: PhotoLibraryService
    @StateObject private var viewModel = DuplicatesViewModel()

    /// 1–10 scale (masks the underlying 0.05–0.50 distance). Default 6 → 0.30.
    @AppStorage("PhotoSwipe.duplicateSensitivity") private var sensitivity: Double = 6

    private var threshold: Double { sensitivity * 0.05 }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )

    var body: some View {
        content
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reloadToolbar }
            .task {
                viewModel.distanceThreshold = threshold
                viewModel.onAppear(using: service)
            }
            .onChange(of: service.libraryVersion) { _, _ in
                viewModel.onLibraryChange(using: service)
            }
            .onChange(of: sensitivity) { _, _ in
                viewModel.updateThreshold(threshold, using: service)
            }
    }

    @ToolbarContentBuilder
    private var reloadToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.isRefreshing {
                ProgressView()
            } else if viewModel.phase == .results || viewModel.phase == .empty {
                Button {
                    viewModel.reload(using: service)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Rescan for duplicates")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .grouping:
            groupingState
        case .empty:
            emptyState
        case .results:
            resultsList
        }
    }

    // MARK: - Sensitivity

    private var sensitivityBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sensitivity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(sensitivity))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.secondary)
                Slider(value: $sensitivity, in: 1...10, step: 1)
                    .accessibilityLabel("Match sensitivity")
                    .accessibilityValue("\(Int(sensitivity)) of 10")
                Image(systemName: "circle.grid.3x3.fill")
                    .foregroundStyle(.secondary)
            }
            Text("Higher finds looser matches; lower keeps only near-identical shots.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Idle / explainer

    private var idleState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Find duplicates")
                .font(.title2.bold())
            Text("PhotoSwipe can scan your library for camera bursts and near-identical shots. This may take a few minutes and runs entirely on your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button {
                viewModel.startFirstScan(using: service)
            } label: {
                Text("Scan library")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Scanning

    private var scanningState: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: viewModel.progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)
            Text(viewModel.total > 0
                 ? "Scanning \(viewModel.processed) of \(viewModel.total)…"
                 : "Preparing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(role: .cancel) {
                viewModel.cancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var groupingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Finding duplicates…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 0) {
            sensitivityBar
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("No duplicates found")
                    .font(.headline)
                Text("Raise sensitivity to find looser matches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        VStack(spacing: 0) {
            sensitivityBar
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.groups) { group in
                        NavigationLink(value: AppRoute.swipe(.duplicateGroup(group))) {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.count) similar")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(previewIDs(for: group), id: \.self) { id in
                    GroupThumbnail(
                        asset: viewModel.asset(for: id),
                        service: service,
                        isKeeper: id == group.suggestedKeeperID
                    )
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group of \(group.count) similar photos")
    }

    /// Show up to a row of thumbnails, keeper first.
    private func previewIDs(for group: DuplicateGroup) -> [String] {
        var ids = group.assetIDs
        if let idx = ids.firstIndex(of: group.suggestedKeeperID) {
            ids.remove(at: idx)
            ids.insert(group.suggestedKeeperID, at: 0)
        }
        return Array(ids.prefix(8))
    }
}

private struct GroupThumbnail: View {
    let asset: PhotoAsset?
    let service: PhotoLibraryService
    let isKeeper: Bool

    @State private var image: UIImage?

    var body: some View {
        Color(.tertiarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if isKeeper {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: asset?.id) {
                guard let asset else { return }
                image = nil
                for await next in service.imageStream(
                    for: asset,
                    targetSize: CGSize(width: 200, height: 200)
                ) {
                    image = next
                }
            }
    }
}
