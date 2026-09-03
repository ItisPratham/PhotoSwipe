import SwiftUI

/// Lists pairs of people the clusterer thinks may be the same person. Each
/// row shows both covers and asks; Yes merges the smaller cluster into the
/// larger one, No is remembered so the pair is never asked again.
struct MergeSuggestionsSheet: View {
    @ObservedObject var viewModel: PeopleViewModel
    let service: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.mergeSuggestions.isEmpty {
                    ContentUnavailableView("No more suggestions",
                                           systemImage: "person.2.badge.gearshape",
                                           description: Text("New matches show up here after a rescan."))
                } else {
                    List(viewModel.mergeSuggestions) { suggestion in
                        row(suggestion)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Same person?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ suggestion: MergeSuggestion) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                person(suggestion.a)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                person(suggestion.b)
            }
            HStack(spacing: 12) {
                Button {
                    viewModel.dismissMerge(suggestion)
                } label: {
                    Text("No")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    viewModel.acceptMerge(suggestion)
                } label: {
                    Text("Yes, merge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.a.displayName) and \(suggestion.b.displayName), same person?")
    }

    /// Long-press a cover to see the full photo before deciding, like every
    /// other thumbnail in the app.
    private func person(_ cluster: PersonCluster) -> some View {
        VStack(spacing: 6) {
            PersonCoverView(cluster: cluster, service: service)
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .contentShape(.contextMenuPreview, Circle())
                .contextMenu {
                    Text(cluster.displayName)
                } preview: {
                    PersonCoverPreview(cluster: cluster, service: service)
                }
            Text(cluster.displayName)
                .font(.caption)
                .lineLimit(1)
            Text("\(cluster.photoCount) photos")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
