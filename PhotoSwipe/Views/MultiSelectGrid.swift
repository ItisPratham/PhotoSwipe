import SwiftUI

/// A reusable multi-select photo grid: tap a cell to toggle it, with a
/// checkmark and a tint on selected cells. Selection is owned by the parent
/// so the parent can drive a batch action (e.g. delete).
struct MultiSelectGrid: View {
    let assets: [PhotoAsset]
    let service: PhotoLibraryService
    @Binding var selection: Set<String>

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 3
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(assets) { asset in
                cell(for: asset)
            }
        }
    }

    private func cell(for asset: PhotoAsset) -> some View {
        let isSelected = selection.contains(asset.id)
        return Button {
            toggle(asset.id)
        } label: {
            Thumbnail(asset: asset, service: service)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                            .fill(Color.accentColor.opacity(0.28))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .white.opacity(0.35))
                        .font(.title3)
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                toggle(asset.id)
            } label: {
                Label(isSelected ? "Deselect" : "Select",
                      systemImage: isSelected ? "circle" : "checkmark.circle")
            }
        } preview: {
            ThumbnailPreview(asset: asset, service: service)
        }
        .accessibilityLabel("Photo from \(asset.formattedDate)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
