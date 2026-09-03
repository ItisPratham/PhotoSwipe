import CoreGraphics
import Foundation
import Photos

/// Bounded-concurrency driver shared by the duplicate and face scans. Runs
/// `work` for each element with at most `maxConcurrency` in flight and hands
/// each result to `onResult` in completion order, on the caller's task, so
/// batching and progress stay sequential. Cancelling the caller cancels the
/// children (each `work` should make its own waits cancelable, see
/// `PhotoKitImages`) and the group drains before this returns.
enum ConcurrentScan {
    static func run<Element: Sendable, Output: Sendable>(
        _ elements: [Element],
        maxConcurrency: Int,
        work: @escaping @Sendable (Element) async -> Output,
        onResult: (Element, Output) async throws -> Void
    ) async throws {
        guard !elements.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Element, Output).self) { group in
            var iterator = elements.makeIterator()

            // Enqueues the next element as a child task, if any remain.
            func enqueueNext() {
                guard let element = iterator.next() else { return }
                group.addTask { (element, await work(element)) }
            }

            for _ in 0..<min(max(1, maxConcurrency), elements.count) { enqueueNext() }

            // As each child finishes, hand off its result and top up the pool.
            for try await (element, output) in group {
                try Task.checkCancellation()
                try await onResult(element, output)
                enqueueNext()
            }
        }
    }
}

/// Async, cancelable PhotoKit image fetches for the scans. Bridging
/// `requestImage` to a continuation frees the cooperative thread while an
/// iCloud original downloads, so the next fetch starts immediately. Task
/// cancellation cancels the PhotoKit request and resumes with nil at once,
/// so a cancelled scan never waits on a download.
enum PhotoKitImages {

    /// A downscaled working image for Vision. With `highQualityFormat`,
    /// Photos may call back twice — a degraded placeholder (skipped) and the
    /// final image. Nil when the image couldn't be loaded (offline, iCloud
    /// download failed, cancelled).
    static func workingImage(
        for asset: PHAsset,
        side: CGFloat,
        resizeMode: PHImageRequestOptionsResizeMode
    ) async -> CGImage? {
        let request = RequestState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                request.continuation = continuation
                let options = PHImageRequestOptions()
                options.isSynchronous = false
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.resizeMode = resizeMode
                let id = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !isDegraded else { return }
                    request.finish(with: image?.cgImage)
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Serialises the request id, the continuation, and the once-only resume
    /// between the PhotoKit callback thread and the cancellation handler.
    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID?
        private var cancelled = false
        private var resumed = false
        var continuation: CheckedContinuation<CGImage?, Never>?

        func started(_ id: PHImageRequestID) {
            lock.lock()
            requestID = id
            let cancelNow = cancelled
            lock.unlock()
            if cancelNow { PHImageManager.default().cancelImageRequest(id) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let id = requestID
            lock.unlock()
            if let id { PHImageManager.default().cancelImageRequest(id) }
            // Don't rely on PhotoKit calling back after a cancel.
            finish(with: nil)
        }

        func finish(with image: CGImage?) {
            lock.lock()
            guard !resumed, let continuation else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            continuation.resume(returning: image)
        }
    }
}
