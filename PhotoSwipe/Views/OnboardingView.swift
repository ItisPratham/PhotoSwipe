import SwiftUI

/// Five-slide first-run tutorial. The first three slides teach the swipe deck
/// by being one: the slide card follows the finger, tilts, and flies off with
/// the same red/green/yellow directional tint as the real deck (left = mark,
/// right = keep, up = favorite). A static "ways in" slide introduces More
/// like this, Screenshots, Categories, and On this day, and the final
/// "review" slide is a static card with a Get-started button.
///
/// Shown once before the permission prompt on first launch (RootView owns the
/// seen-flag), and re-openable from the menu afterwards. `onFinish` is called
/// from the last slide's button — caller decides whether to set the flag or
/// just dismiss a re-opened sheet.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var currentSlide = 0
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var exitOffset: CGSize = .zero
    @State private var isExiting = false

    private let slides: [Slide] = [
        Slide(
            symbol: "hand.draw.fill",
            symbolColor: .red,
            title: "Swipe left to mark",
            body: "Swiping left marks a photo for deletion. Nothing is removed yet, so you can move fast without worrying.",
            hint: "Swipe left to continue",
            allowed: .left
        ),
        Slide(
            symbol: "checkmark.seal.fill",
            symbolColor: .green,
            title: "Swipe right to keep",
            body: "Kept photos are marked as reviewed and won't come back into the deck, so you always move forward.",
            hint: "Swipe right to continue",
            allowed: .right
        ),
        Slide(
            symbol: "heart.fill",
            symbolColor: .yellow,
            title: "Swipe up to favorite",
            body: "Swiping up keeps the photo and marks it as a favorite in Photos. You can switch this to \"add to an album\" in Settings.",
            hint: "Swipe up to continue",
            allowed: .up
        ),
        Slide(
            symbol: "photo.stack",
            symbolColor: .purple,
            title: "Smarter ways in",
            body: "Tap the stack icon on a photo to see its closest look-alikes. Browse can also pull out your screenshots, show what you shot on this day in past years, and sort photos into categories like receipts, food, pets, and memes. It all happens on your phone.",
            hint: nil,
            allowed: nil
        ),
        Slide(
            symbol: "tray.full.fill",
            symbolColor: .accentColor,
            title: "Review, then delete in bulk",
            body: "Tap Review to see everything you've marked, untick anything you want to spare, then confirm to delete them all in one system prompt.",
            hint: nil,
            allowed: nil
        )
    ]

    private let swipeThreshold: CGFloat = 100
    private let exitDistance: CGFloat = 800

    /// The offset actually applied to the card. During a drag we follow the
    /// gesture; while flinging off we switch to the explicit exit offset so
    /// GestureState resetting to zero doesn't snap the card back.
    private var displayOffset: CGSize {
        isExiting ? exitOffset : dragTranslation
    }

    /// −1…1 for the horizontal slides, 0…1 (upward) for the favorite slide.
    private var swipeProgress: CGFloat {
        if allowedDirection == .up {
            return max(0, min(1, -displayOffset.height / swipeThreshold))
        }
        return max(-1, min(1, displayOffset.width / swipeThreshold))
    }

    private var isLastSlide: Bool {
        currentSlide == slides.count - 1
    }

    /// The last slide is static (button-driven); only 1 and 2 accept swipes.
    private var isSwipableSlide: Bool {
        slides[currentSlide].allowed != nil
    }

    private var allowedDirection: SwipeDirection? {
        slides[currentSlide].allowed
    }

    /// Clamps the drag translation to the current slide's allowed direction so
    /// the card only moves the "correct" way — swiping the wrong direction has
    /// no visible effect, teaching the mechanic.
    private func clamp(_ translation: CGSize) -> CGSize {
        switch allowedDirection {
        case .left:
            return CGSize(width: min(translation.width, 0),
                          height: translation.height)
        case .right:
            return CGSize(width: max(translation.width, 0),
                          height: translation.height)
        case .up:
            return CGSize(width: 0, height: min(translation.height, 0))
        case .none:
            return .zero
        }
    }

    var body: some View {
        ZStack {
            swipeTint
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 24) {
                Spacer()

                slideCard(for: slides[currentSlide])
                    .padding(.horizontal, 24)
                    .offset(displayOffset)
                    .rotationEffect(.degrees(Double(displayOffset.width / 20)))
                    .animation(
                        .interactiveSpring(response: 0.35, dampingFraction: 0.7),
                        value: dragTranslation
                    )
                    .gesture(swipeGesture)
                    .id(currentSlide)

                Spacer()

                pageIndicator

                footerControl
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Card

    private func slideCard(for slide: Slide) -> some View {
        VStack(spacing: 20) {
            Image(systemName: slide.symbol)
                .font(.system(size: 84))
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
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tint

    /// Full-screen tint that grows with the drag, red for left / green for
    /// right — same visual language as the real swipe deck.
    private var swipeTint: some View {
        let progress = swipeProgress
        let tint: Color
        switch allowedDirection {
        case .up: tint = .yellow
        default: tint = progress > 0 ? .green : .red
        }
        return tint.opacity(Double(abs(progress)) * 0.22)
    }

    // MARK: - Page dots

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<slides.count, id: \.self) { index in
                Circle()
                    .fill(index == currentSlide
                          ? Color.accentColor
                          : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerControl: some View {
        if isLastSlide {
            Button {
                onFinish()
            } label: {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if !isSwipableSlide {
            // A static, informational slide advances with a button.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentSlide = min(currentSlide + 1, slides.count - 1)
                }
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if let hint = slides[currentSlide].hint {
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 44)
        }
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = clamp(value.translation)
            }
            .onEnded { value in
                let clamped = clamp(value.translation)
                let committed = allowedDirection == .up
                    ? -clamped.height > swipeThreshold
                    : abs(clamped.width) > swipeThreshold
                guard committed else { return }
                completeSwipe(translation: clamped)
                // Below threshold: GestureState auto-resets to zero and the
                // .animation modifier springs the card back to centre.
            }
    }

    private func completeSwipe(translation: CGSize) {
        let exit: CGSize
        if allowedDirection == .up {
            exit = CGSize(width: 0, height: -exitDistance)
        } else {
            exit = CGSize(width: translation.width > 0 ? exitDistance : -exitDistance,
                          height: translation.height)
        }
        exitOffset = translation
        isExiting = true
        withAnimation(.easeOut(duration: 0.25)) {
            exitOffset = exit
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            currentSlide = min(currentSlide + 1, slides.count - 1)
            isExiting = false
            exitOffset = .zero
        }
    }
}

private enum SwipeDirection {
    case left, right, up
}

private struct Slide: Identifiable {
    let id = UUID()
    let symbol: String
    let symbolColor: Color
    let title: String
    let body: String
    let hint: String?
    /// Which swipe direction advances this slide. `nil` = no swipe (button).
    let allowed: SwipeDirection?
}

#Preview {
    OnboardingView(onFinish: {})
}
