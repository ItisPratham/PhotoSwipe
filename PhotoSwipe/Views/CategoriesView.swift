import SwiftUI

/// The Categories screen, pushed from Browse. Explains the sorting pass until
/// the user opts in, shows progress with Cancel while it runs, then lists the
/// categories with counts. A category opens a Browse-style grid of its photos.
struct CategoriesView: View {
    @ObservedObject var service: PhotoLibraryService
    @ObservedObject var viewModel: CategoriesViewModel

    var body: some View {
        content
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.viewAppeared()
                viewModel.onAppear(using: service)
            }
            .onDisappear { viewModel.viewDisappeared() }
            .onChange(of: service.libraryVersion) { _, _ in
                viewModel.onLibraryChange(using: service)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            explainer
        case .indexing, .categorizing:
            progress
        case .results:
            list
        }
    }

    private var explainer: some View {
        ContentUnavailableView {
            Label("Sort by what's in the photo", systemImage: "square.grid.2x2")
        } description: {
            Text("PhotoSwipe can look at each photo on your phone and file it under receipts, documents, whiteboards, food, pets, or memes. Nothing is uploaded. The first pass takes a few minutes.")
        } actions: {
            Button("Sort my library") { viewModel.start(using: service) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var progress: some View {
        VStack(spacing: 20) {
            ProgressView(value: viewModel.progress) {
                Text(viewModel.phase == .indexing ? "Indexing photos…" : "Sorting into categories…")
            } currentValueLabel: {
                Text(viewModel.total > 0 ? "\(viewModel.processed) of \(viewModel.total)" : "Preparing…")
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            Button("Cancel") { viewModel.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(AssetCategory.allCases) { category in
                    let count = viewModel.count(for: category)
                    NavigationLink(value: AppRoute.category(category, ids: viewModel.idsByCategory[category] ?? [])) {
                        HStack(spacing: 14) {
                            Image(systemName: category.systemImage)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(category.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(count == 0)
                    .opacity(count == 0 ? 0.5 : 1)
                    .accessibilityLabel("\(category.title), \(count) photos")
                }
            } header: {
                if viewModel.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Sorting new photos…")
                    }
                }
            } footer: {
                Text("Sorted on your phone from what Vision can see in each photo. It's a best guess: a category can miss things or include a few it shouldn't.")
            }
        }
        .listStyle(.insetGrouped)
    }
}
