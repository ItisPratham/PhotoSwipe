import SwiftUI
import WidgetKit

/// The home-screen widget. It reads **only** `summary.json` from the App
/// Group: the app's review file, indexes, and defaults are unreachable from an
/// extension, and nothing here falls back to them.
///
/// Timeline entries are generated for the next few midnights so the streak,
/// the seven-day strip, and the month total keep ageing correctly even if the
/// app is never opened. The app requests a reload after each successful
/// publish, but WidgetKit decides when that actually happens — the timeline is
/// what keeps a stale snapshot honest in the meantime.
@main
struct PhotoSwipeWidgets: WidgetBundle {
    var body: some Widget { PhotoSwipeSummaryWidget() }
}

struct PhotoSwipeSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CleanupSummary.widgetKind, provider: SummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PhotoSwipe")
        .description("Space freed this month, photos waiting to be deleted, and your swipe streak.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SummaryEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has never published, the App Group is unavailable, or
    /// the file is corrupt. The view says so rather than showing zeroes.
    let summary: CleanupSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), summary: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: Date(), summary: CleanupSummary.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let summary = CleanupSummary.read()
        let now = Date()
        let calendar = Calendar.localGregorian
        // Now, then each of the next three local midnights: enough for the
        // strip to slide and a month to roll over before the next reload.
        var dates = [now]
        var midnight = calendar.startOfDay(for: now)
        for _ in 0..<3 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
            dates.append(next)
        }
        let entries = dates.map { SummaryEntry(date: $0, summary: summary) }
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

struct SummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SummaryEntry

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private var monthBytes: Int64 {
        entry.summary?.bytesFreed(inMonthOf: entry.date) ?? 0
    }

    private var markedText: String {
        guard let count = entry.summary?.markedCount, count > 0 else { return "Nothing marked" }
        return "\(count) marked"
    }

    var body: some View {
        if entry.summary == nil {
            unavailable
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                if family == .systemMedium {
                    Spacer(minLength: 0)
                    activityStrip
                    cleanLink
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Open PhotoSwipe to update")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Freed this month")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.byteFormatter.string(fromByteCount: monthBytes))
                .font(.title2.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(markedText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Freed this month, \(Self.byteFormatter.string(fromByteCount: monthBytes)). \(markedText).")
    }

    /// Seven days ending on the entry's own date, so the strip slides with the
    /// calendar rather than with the snapshot.
    private var activityStrip: some View {
        let days = CleanupSummary.recentDayKeys(endingAt: entry.date)
        let active = Set(entry.summary?.activeDayKeys ?? [])
        let streak = entry.summary?.streakDays ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(active.contains(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(height: 14)
                }
            }
            Text(streak > 0 ? "\(streak)-day streak" : "No streak yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(active.count) active days in the last seven. " +
                            (streak > 0 ? "\(streak) day streak." : "No streak yet."))
    }

    private var cleanLink: some View {
        Link(destination: CleanRequest().url) {
            Label("Clean", systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
        }
    }
}

#Preview(as: .systemMedium) {
    PhotoSwipeSummaryWidget()
} timeline: {
    SummaryEntry(date: .now, summary: nil)
    SummaryEntry(date: .now, summary: CleanupSummary(
        markedCount: 12, totalBytesFreed: 8_400_000_000, totalPhotosDeleted: 940,
        lastSessionDate: .now, streakDays: 4, monthBytesFreed: 1_250_000_000,
        generatedAt: .now, monthKey: CleanupSummary.monthKey(.now),
        activeDayKeys: CleanupSummary.recentDayKeys(endingAt: .now).suffix(4)))
}
