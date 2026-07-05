import SwiftUI

/// Cold-launch splash. Renders the app's fanned-deck logo: the deck fades in
/// already fanned, settles, then the front card swipes away — echoing the app's
/// core gesture — as the whole splash crossfades into the content beneath it.
///
/// RootView shows this over whatever loads first (onboarding, the permission
/// screen, or the Browse grid). The background is `.systemBackground` so the
/// crossfade into any of those is seamless in both light and dark.
struct LaunchView: View {
    /// Flips true once the underlying content is ready (library loaded, or
    /// nothing to load) *and* a minimum on-screen time has elapsed. Triggers
    /// the front-card swipe and the hand-off.
    let readyToReveal: Bool

    /// Called after the front card has swiped away, so the host can crossfade
    /// the splash out and reveal the content.
    let onFinished: () -> Void

    /// Drives the initial fade-in of the (already-fanned) deck.
    @State private var appeared = false
    @State private var frontSwiped = false

    private struct Card: Identifiable {
        let id = UUID()
        let color: Color
        let angle: Double
    }

    /// Same five colours and fan angles as the app icon (front card = red,
    /// carrying the swipe arrow).
    private let cards: [Card] = [
        Card(color: Color(red: 0.608, green: 0.365, blue: 0.898), angle: -30), // #9B5DE5
        Card(color: Color(red: 0.239, green: 0.608, blue: 1.000), angle: -15), // #3D9BFF
        Card(color: Color(red: 0.239, green: 0.839, blue: 0.549), angle: 0),   // #3DD68C
        Card(color: Color(red: 1.000, green: 0.788, blue: 0.239), angle: 15),  // #FFC93D
        Card(color: Color(red: 1.000, green: 0.353, blue: 0.373), angle: 30),  // #FF5A5F
    ]

    private let cardSize = CGSize(width: 92, height: 132)

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                deck
                wordmark
            }
            // Unveil the whole deck rather than unfolding it card-by-card.
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96)
        }
        .onAppear(perform: animateIn)
        .onChange(of: readyToReveal) { ready in
            if ready { reveal() }
        }
    }

    // MARK: - Deck

    private var deck: some View {
        ZStack {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                cardView(card, isFront: index == cards.count - 1)
            }
        }
        // Headroom so the bottom-anchored fan isn't clipped as cards rotate up.
        .frame(width: 240, height: 240)
    }

    private func cardView(_ card: Card, isFront: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(card.color)
            .frame(width: cardSize.width, height: cardSize.height)
            .overlay {
                if isFront {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            // Fanned from a shared bottom pivot, matching the icon.
            .rotationEffect(.degrees(card.angle), anchor: .bottom)
            // Front card swipes away on reveal.
            .offset(x: isFront && frontSwiped ? 460 : 0)
            .rotationEffect(isFront && frontSwiped ? .degrees(18) : .zero)
            .opacity(isFront && frontSwiped ? 0 : 1)
    }

    private var wordmark: some View {
        Text("PhotoSwipe")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
    }

    // MARK: - Animation

    private func animateIn() {
        // Gently fade the already-fanned deck in, then let it settle until the
        // reveal triggers the front-card swipe.
        withAnimation(.easeOut(duration: 0.6)) {
            appeared = true
        }
    }

    private func reveal() {
        withAnimation(.easeIn(duration: 0.7)) {
            frontSwiped = true
        }
        // Let the swipe read for a beat, then hand off for the crossfade.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            onFinished()
        }
    }
}

#Preview {
    LaunchView(readyToReveal: false, onFinished: {})
}
