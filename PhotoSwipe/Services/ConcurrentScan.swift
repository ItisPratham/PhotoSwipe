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
/// iCloud original downloads, so the next fetch starts immediately.
///
/// Cancellation resumes the caller with nil at once but deliberately does
/// **not** call `cancelImageRequest`: cancelling network-backed requests
/// mid-download, four at a time, was followed on device by PhotoKit never
/// completing another request in the process (scan stuck at 0, every
/// thumbnail blank) until relaunch. Letting the in-flight request finish on
/// its own and dropping the result costs at most four downloads.
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
        // A child created just as its group was cancelled must not issue a
        // request it will never wait for.
        guard !Task.isCancelled else { return nil }
        let request = RequestState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                // If cancellation raced in before the continuation existed,
                // resume now instead of leaking the child forever.
                guard request.attach(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.isSynchronous = false
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.resizeMode = resizeMode
                PhotoKitDiag.requestStarted("scan")
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !isDegraded else { return }
                    PhotoKitDiag.requestFinished("scan")
                    request.finish(with: image?.cgImage)
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Serialises the continuation and the once-only resume between the
    /// PhotoKit callback thread and the cancellation handler.
    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var resumed = false
        private var continuation: CheckedContinuation<CGImage?, Never>?

        /// Stores the continuation. Returns false if cancellation already
        /// happened, in which case the caller resumes immediately.
        func attach(_ continuation: CheckedContinuation<CGImage?, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { resumed = true; return false }
            self.continuation = continuation
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            // Resume the waiter now; the PhotoKit request finishes on its own
            // and its late result is dropped by the once-only guard.
            finish(with: nil)
        }

        func finish(with image: CGImage?) {
            lock.lock()
            guard !resumed, let continuation else { lock.unlock(); return }
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: image)
        }
    }
}
