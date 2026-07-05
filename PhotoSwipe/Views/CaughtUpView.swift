import SwiftUI

/// Shown when the deck has no more unjudged photos. Communicates progress
/// (how many the user has reviewed) and the implicit promise that new photos
/// will flow in automatically on future launches.
struct CaughtUpView: View {
    let totalReviewed: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)

            Text("All caught up 🎉")
                .font(.title2.bold())

            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                dismiss()
            } label: {
                Text("Back to Browse")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if totalReviewed > 0 {
            let suffix = totalReviewed == 1 ? "" : "s"
            return "You've reviewed \(totalReviewed) photo\(suffix). New photos you take will show up next time."
        }
        return "Nothing to review yet. New photos you take will show up next time."
    }
}

#Preview("Fresh") {
    CaughtUpView(totalReviewed: 0)
}

#Preview("After a session") {
    CaughtUpView(totalReviewed: 312)
}
