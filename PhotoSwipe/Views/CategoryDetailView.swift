import SwiftUI

/// One category's photos as a Browse-style, day-grouped grid. A "Swipe all"
/// row at the top opens the whole category; tapping a photo or a day header
/// starts the deck there and continues to newer photos, like Browse.
struct CategoryDetailView: View {
    let category: AssetCategory
    @ObservedObject var service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    @StateObject private var viewModel: PhotoSetViewModel
    @State private var scrollSectionID: Date?
    @State private var fastScrollIndex = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    init(category: AssetCategory, ids: [String], service: PhotoLibraryService, store: ReviewStore) {
        self.category = category
        self.service = service
        self.store = store
        _viewModel = StateObject(wrappedValue: PhotoSetViewModel(ids: ids))
    }

    var body: some View {
        content
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.thickMaterial, for: .navigationBar)
            .task { await viewModel.loadIfNeeded(using: service) }
            .onChange(of: service.libraryVersion) { _, _ in
                Task { await viewModel.loadIfNeeded(using: service) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.sections.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: category.systemImage)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    NavigationLink(value: AppRoute.swipe(.category(category, ids: viewModel.oldestFirstIDs))) {
                        BrowseEntryRow(title: "Swipe all",
                                       subtitle: "\(viewModel.count) \(viewModel.count == 1 ? "photo" : "photos"), oldest first",
                                       systemImage: "hand.tap.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                    .padding(.top, 12)

                    ForEach(viewModel.sections) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(section.assets) { asset in
                                    NavigationLink(value: AppRoute.swipe(.category(category, ids: viewModel.idsFrom(asset)))) {
                                        Thumbnail(asset: asset,
                                                  service: service,
                                                  decision: store.decision(for: asset.id))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Start swiping from \(asset.formattedDate)")
                                    .contextMenu {
                                        NavigationLink(value: AppRoute.swipe(.category(category, ids: viewModel.idsFrom(asset)))) {
                                            Label("Start swiping from here", systemImage: "play.circle")
                                        }
                                    } preview: {
                                        ThumbnailPreview(asset: asset, service: service)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        } header: {
                            NavigationLink(value: AppRoute.swipe(.category(category, ids: viewModel.idsFrom(day: section)))) {
                                HStack(spacing: 6) {
                                    Text(section.id, format: .dateTime.month(.wide).day().year())
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.vertical, 6)
                                .background(Color.black)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start swiping from \(section.id.formatted(.dateTime.month(.wide).day().year()))")
                        }
                        .id(section.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrollSectionID, anchor: .top)
            .onChange(of: scrollSectionID) { _, id in
                guard let id,
                      let index = viewModel.sections.firstIndex(where: { $0.id == id })
                else { return }
                fastScrollIndex = index
            }
            .overlay(alignment: .leading) {
                if viewModel.sections.count > 1 {
                    PhotoFastScroller(
                        itemCount: viewModel.sections.count,
                        currentIndex: fastScrollIndex,
                        onSelect: scroll(to:)
                    )
                }
            }
        }
    }

    private func scroll(to index: Int) {
        guard viewModel.sections.indices.contains(index) else { return }
        fastScrollIndex = index
        scrollSectionID = viewModel.sections[index].id
    }
}
