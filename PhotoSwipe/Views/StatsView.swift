import SwiftUI

/// Read-only activity log. Shows cumulative freed space (headline), the
/// running count of photos deleted, and a chronological list of every
/// successful batch. Deliberately no restore button — iOS already provides
/// Recently Deleted, and re-importing files isn't PhotoSwipe's job.
struct StatsView: View {
    @ObservedObject var stats: StatsStore
    @Environment(\.dismiss) private var dismiss

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if stats.history.isEmpty {
                    emptyState
                } else {
                    populatedList
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Populated

    private var populatedList: some View {
        List {
            Section {
                headline
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }

            Section("Batches") {
                ForEach(stats.history) { record in
                    row(for: record)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Freed", systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                Text(Self.byteFormatter.string(fromByteCount: stats.totalBytesFreed))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.footnote)
                Text(deletedSummary)
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var deletedSummary: String {
        let n = stats.totalPhotosDeleted
        return "\(n) \(n == 1 ? "photo" : "photos") deleted"
    }

    private func row(for record: DeleteRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: record.date))
                    .font(.body)
                Text("\(record.count) \(record.count == 1 ? "photo" : "photos")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: record.bytesFreed))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No deletes yet")
                .font(.headline)
            Text("Confirm your first batch delete and it'll show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("With history") {
    let stats = StatsStore()
    stats.recordDelete(count: 12, bytesFreed: 84_000_000)
    stats.recordDelete(count: 3, bytesFreed: 5_600_000)
    return StatsView(stats: stats)
}

#Preview("Empty") {
    StatsView(stats: StatsStore())
}
