import DMScrollBar
import SwiftUI
import UIKit

/// Attaches DMScrollBar to SwiftUI's backing scroll view without exposing
/// offsets or programmatic scrolling to SwiftUI.
struct ScrollBarInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.install(from: view)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    static func needsScrollBar(contentSize: CGSize, bounds: CGRect, adjustedContentInset: UIEdgeInsets) -> Bool {
        contentSize.height > bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(from: self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.install(from: self)
        }
    }

    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var scrollBar: DMScrollBar?
        private var previousIndicatorVisibility: Bool?
        private var pendingInstall: DispatchWorkItem?
        /// DMScrollBar lays its scroll view out during initialization. That
        /// synchronously invokes ProbeView.layoutSubviews(), so installation
        /// must not re-enter before `scrollBar` has been assigned.
        private var isInstalling = false

        deinit { uninstall() }

        func install(from probe: UIView) {
            guard let candidate = ancestorScrollView(of: probe) else {
                scheduleInstall(from: probe)
                return
            }

            pendingInstall?.cancel()
            pendingInstall = nil

            if scrollView !== candidate {
                uninstall()
                scrollView = candidate
            }

            guard scrollBar == nil else {
                refreshVisibility(in: candidate)
                return
            }

            guard !isInstalling else { return }
            isInstalling = true
            defer { isInstalling = false }

            previousIndicatorVisibility = candidate.showsVerticalScrollIndicator
            let bar = DMScrollBar(scrollView: candidate, configuration: Self.configuration)
            candidate.scrollBar = bar
            scrollBar = bar
            refreshVisibility(in: candidate)
        }

        func uninstall() {
            pendingInstall?.cancel()
            pendingInstall = nil
            guard let scrollView else { return }
            if scrollView.scrollBar === scrollBar { scrollView.scrollBar = nil }
            scrollBar?.removeFromSuperview()
            if let previousIndicatorVisibility { scrollView.showsVerticalScrollIndicator = previousIndicatorVisibility }
            self.scrollBar = nil
            self.scrollView = nil
            previousIndicatorVisibility = nil
        }

        private func scheduleInstall(from probe: UIView) {
            guard pendingInstall == nil else { return }
            let task = DispatchWorkItem { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.pendingInstall = nil
                self.install(from: probe)
            }
            pendingInstall = task
            DispatchQueue.main.async(execute: task)
        }

        private func ancestorScrollView(of view: UIView) -> UIScrollView? {
            sequence(first: view.superview, next: { $0?.superview })
                .compactMap { $0 as? UIScrollView }
                .first
        }

        private func refreshVisibility(in scrollView: UIScrollView) {
            scrollBar?.isHidden = !ScrollBarInstaller.needsScrollBar(
                contentSize: scrollView.contentSize,
                bounds: scrollView.bounds,
                adjustedContentInset: scrollView.adjustedContentInset
            )
        }

        private static let configuration = DMScrollBar.Configuration(
            isAlwaysVisible: false,
            shouldDecelerate: false,
            indicator: .init(
                normalState: .iosStyle(width: 3),
                activeState: .custom(config: .iosStyle(width: 8)),
                insetsFollowsSafeArea: true,
                animation: .defaultTiming(with: .fade)
            ),
            infoLabel: nil
        )
    }
}
