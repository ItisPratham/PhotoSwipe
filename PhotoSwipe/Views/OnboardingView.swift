import SwiftUI

/// Three-slide first-run tutorial. Shown once before the permission prompt on
/// first launch (RootView owns the seen-flag), and re-openable from the menu
/// afterwards. The final slide's primary action calls `onFinish`, which the
/// caller uses to set the seen-flag or dismiss a re-opened sheet.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var currentSlide = 0

    private let slides: [Slide] = [
        Slide(
            symbol: "hand.draw.fill",
            symbolColor: .red,
            title: "Swipe left to mark",
            body: "Swiping left marks a photo for deletion — nothing is removed yet, so you can plough through your library without fear."
        ),
        Slide(
            symbol: "checkmark.seal.fill",
            symbolColor: .green,
            title: "Swipe right to keep",
            body: "Kept photos are marked as reviewed and won't come back into the deck, so you always move forward."
        ),
        Slide(
            symbol: "tray.full.fill",
            symbolColor: .accentColor,
            title: "Review, then delete in bulk",
            body: "Tap Review to see everything you've marked, untick anything you want to spare, then confirm to delete them all in one system prompt."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentSlide) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    SlideView(slide: slide)
                        .tag(index)
                        .padding(.horizontal, 24)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: primaryAction) {
                Text(isLastSlide ? "Get started" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    private var isLastSlide: Bool {
        currentSlide == slides.count - 1
    }

    private func primaryAction() {
        if isLastSlide {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentSlide += 1
            }
        }
    }
}

private struct Slide: Identifiable {
    let id = UUID()
    let symbol: String
    let symbolColor: Color
    let title: String
    let body: String
}

private struct SlideView: View {
    let slide: Slide

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: slide.symbol)
                .font(.system(size: 88))
                .foregroundStyle(slide.symbolColor)
                .accessibilityHidden(true)

            Text(slide.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(slide.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
