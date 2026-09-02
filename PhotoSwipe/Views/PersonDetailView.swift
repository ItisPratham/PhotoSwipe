import SwiftUI

/// A person's detail screen. Offers both outcomes the spec calls for: **Clean**
/// (a swipe deck scoped to this person via `DeckSource.person`) and **Select**
/// (a multi-select grid with batched delete). Also renames or hides the cluster.
struct PersonDetailView: View {
    let service: PhotoLibraryService
    @StateObject private var viewModel: PersonDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var draftName = ""

    init(cluster: PersonCluster, service: PhotoLibraryService, stats: StatsStore) {
        self.service = service
        _viewModel = StateObject(
            wrappedValue: PersonDetailViewModel(cluster: cluster, stats: stats)
        )
    }

    var body: some View {
        content
            .navigationTitle(viewModel.name ?? "Unnamed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { optionsMenu }
            .task { await viewModel.load(using: service) }
            .alert("Name this person", isPresented: $showRename) {
                TextField("Name", text: $draftName)
                Button("Save") { Task { await viewModel.rename(to: draftName) } }
                Button("Cancel", role: .cancel) {}
            }
            .overlay(alignment: .top) { freedBanner }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.lastFreedBytes)
            .onChange(of: viewModel.lastFreedBytes) { _, value in
                guard value != nil else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    viewModel.lastFreedBytes = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    cleanLink
                    MultiSelectGrid(assets: viewModel.assets,
                                    service: service,
                                    selection: $viewModel.selection)
                        .padding(.horizontal, 4)
                }
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.hasSelection { deleteBar }
            }
        }
    }

    private var cleanLink: some View {
        NavigationLink(value: AppRoute.swipe(.person(viewModel.assets.map(\.id)))) {
            BrowseEntryRow(title: "Clean these photos",
                           subtitle: "Swipe through \(viewModel.assets.count) photos",
                           systemImage: "hand.tap.fill")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .disabled(viewModel.assets.isEmpty)
    }

    private var deleteBar: some View {
        HStack {
            Button("Deselect") { viewModel.clearSelection() }
            Spacer()
            Button(role: .destructive) {
                Task { await viewModel.deleteSelected(using: service) }
            } label: {
                Text("Delete (\(viewModel.selection.count))").bold()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var optionsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    draftName = viewModel.name ?? ""
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task {
                        await viewModel.hidePerson()
                        dismiss()
                    }
                } label: {
                    Label("Hide person", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Person options")
            }
        }
    }

    @ViewBuilder
    private var freedBanner: some View {
        if let bytes = viewModel.lastFreedBytes {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.green)
                Text("Freed ~\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.headline)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
