import SwiftUI

/// The Browse "Categories" block: an opt-in explainer until the first pass
/// has run, progress with Cancel while it runs, then a two-column grid of
/// the categories that found anything, each opening its own deck.
struct CategoriesSection: View {
    @ObservedObject var viewModel: CategoriesViewModel
    let service: PhotoLibraryService

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Categories")
                    .font(.headline)
                if viewModel.isRefreshing {
                    ProgressView().scaleEffect(0.75)
                }
                Spacer()
                if viewModel.phase == .results {
                    Text("Sorted on your phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch viewModel.phase {
            case .idle:
                explainer
            case .indexing, .categorizing:
                progress
            case .results:
                grid
            }
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .task { viewModel.onAppear(using: service) }
        .onChange(of: service.libraryVersion) { _, _ in
            viewModel.onLibraryChange(using: service)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Looks at each photo on your phone to sort it into documents, receipts, food, pets and more. Nothing is uploaded. Takes a few minutes the first time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                viewModel.start(using: service)
            } label: {
                Text("Categorize library")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.cardPadding)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: viewModel.progress) {
                Text(viewModel.phase == .indexing ? "Indexing photos…" : "Sorting into categories…")
                    .font(.subheadline)
            } currentValueLabel: {
                Text(viewModel.total > 0 ? "\(viewModel.processed) of \(viewModel.total)" : "Preparing…")
                    .font(.caption)
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            Button("Cancel") { viewModel.cancel() }
                .font(.subheadline)
        }
        .padding(Theme.Spacing.cardPadding)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private var grid: some View {
        let populated = AssetCategory.allCases.filter { viewModel.count(for: $0) > 0 }
        if populated.isEmpty {
            Text("Nothing sorted yet — new photos are categorized as they arrive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(populated) { category in
                    NavigationLink(
                        value: AppRoute.swipe(.category(category, ids: viewModel.idsByCategory[category] ?? []))
                    ) {
                        CategoryCard(category: category, count: viewModel.count(for: category))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(category.title), \(viewModel.count(for: category)) photos")
                }
            }
        }
    }
}

/// One category tile: icon, title, count.
private struct CategoryCard: View {
    let category: AssetCategory
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: category.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count) \(count == 1 ? "photo" : "photos")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.cardPadding)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}
