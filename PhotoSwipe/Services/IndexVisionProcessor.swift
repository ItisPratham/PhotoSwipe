import CoreGraphics
import Foundation
import Vision

/// Limits duplicate/category Vision work independently from PhotoKit fetching.
/// Two analyses may run at once; additional tasks suspend without blocking a
/// cooperative thread, and cancellation is forwarded to active `VNRequest`s.
actor IndexVisionProcessor {
    static let shared = IndexVisionProcessor()
    static let maxConcurrentAnalyses = 2

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeIDs: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []

    nonisolated func indexedAsset(
        localIdentifier: String,
        image: CGImage,
        byteSize: Int64,
        includeCategories: Bool
    ) async throws -> IndexedAsset? {
        let cancellation = CancellationState()
        return try await withPermit {
            try await Self.runDetached(cancellation: cancellation) {
                try Self.performIndexedAsset(
                    localIdentifier: localIdentifier,
                    image: image,
                    byteSize: byteSize,
                    includeCategories: includeCategories,
                    cancellation: cancellation
                )
            }
        }
    }

    nonisolated func categoryMeasurement(for image: CGImage) async throws -> CategoryMeasurement {
        let cancellation = CancellationState()
        return try await withPermit {
            try await Self.runDetached(cancellation: cancellation) {
                try Self.performCategoryMeasurement(for: image, cancellation: cancellation)
            }
        }
    }

    nonisolated func categoryMeasurementIfPossible(for image: CGImage) async -> CategoryMeasurement? {
        try? await categoryMeasurement(for: image)
    }

    /// Acquires one of the two analysis slots without holding the actor while
    /// Vision runs. The synchronous work itself executes on a detached task
    /// because Vision has no async request-handler API.
    private nonisolated func withPermit<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await acquire(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        guard acquired else { throw CancellationError() }

        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release(id)
            return result
        } catch {
            await release(id)
            throw error
        }
    }

    private func acquire(_ id: UUID) async -> Bool {
        if cancelled.remove(id) != nil { return false }
        guard activeIDs.count >= Self.maxConcurrentAnalyses else {
            activeIDs.insert(id)
            return true
        }
        return await withCheckedContinuation { continuation in
            if cancelled.remove(id) != nil {
                continuation.resume(returning: false)
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard !activeIDs.contains(id) else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else {
            // Cancellation can arrive before `acquire` reaches this actor.
            cancelled.insert(id)
        }
    }

    private func release(_ id: UUID) {
        guard activeIDs.remove(id) != nil else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if cancelled.remove(next.id) != nil {
                next.continuation.resume(returning: false)
                continue
            }
            activeIDs.insert(next.id)
            next.continuation.resume(returning: true)
            return
        }
    }

    private static func runDetached<T: Sendable>(
        cancellation: CancellationState,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            PhotoKitDiag.requestStarted("vision:active")
            defer { PhotoKitDiag.requestFinished("vision:active") }
            try cancellation.check()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    private static func performIndexedAsset(
        localIdentifier: String,
        image: CGImage,
        byteSize: Int64,
        includeCategories: Bool,
        cancellation: CancellationState
    ) throws -> IndexedAsset? {
        try cancellation.check()
        guard let vector = try featurePrintVector(from: image, cancellation: cancellation) else {
            return nil
        }

        try cancellation.check()
        let sharpness = ImageQuality.sharpness(of: image)
        let aesthetics = includeCategories
            ? try aesthetics(of: image, cancellation: cancellation)
            : nil

        var indexed = IndexedAsset(
            localIdentifier: localIdentifier,
            vector: vector,
            byteSize: byteSize,
            sharpness: sharpness,
            aestheticScore: aesthetics?.score
        )
        if includeCategories {
            indexed.categories = try categories(
                in: image,
                sharpness: sharpness,
                aesthetics: aesthetics,
                cancellation: cancellation
            )
        }
        return indexed
    }

    private static func performCategoryMeasurement(
        for image: CGImage,
        cancellation: CancellationState
    ) throws -> CategoryMeasurement {
        try cancellation.check()
        let sharpness = ImageQuality.sharpness(of: image)
        let aesthetics = try aesthetics(of: image, cancellation: cancellation)
        return try categories(
            in: image,
            sharpness: sharpness,
            aesthetics: aesthetics,
            cancellation: cancellation
        )
    }

    private static func featurePrintVector(
        from image: CGImage,
        cancellation: CancellationState
    ) throws -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try perform([request], on: image, label: "print", cancellation: cancellation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }
        let vector = FeaturePrintCodec.vector(from: observation)
        return vector.isEmpty ? nil : vector
    }

    private static func aesthetics(
        of image: CGImage,
        cancellation: CancellationState
    ) throws -> (score: Float, isUtility: Bool)? {
        guard #available(iOS 18.0, *) else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        do {
            try perform([request], on: image, label: "aesthetics", cancellation: cancellation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return (observation.overallScore, observation.isUtility)
    }

    private static func categories(
        in image: CGImage,
        sharpness: Float?,
        aesthetics: (score: Float, isUtility: Bool)?,
        cancellation: CancellationState
    ) throws -> CategoryMeasurement {
        let classify = VNClassifyImageRequest()
        let animals = VNRecognizeAnimalsRequest()
        let text = VNDetectTextRectanglesRequest()
        text.reportCharacterBoxes = false

        do {
            try perform(
                [classify, animals, text],
                on: image,
                label: "categories",
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the old best-effort behavior: an individual Vision
            // failure produces empty category signals and is retried later.
        }

        let labels = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) || $0.confidence >= 0.5 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(8)
            .map { ($0.identifier, $0.confidence) }

        let hasAnimal = (animals.results ?? []).contains { observation in
            observation.labels.contains { $0.confidence >= 0.75 }
        }

        let coverage = (text.results ?? []).reduce(Float(0)) { sum, observation in
            let area = Float(observation.boundingBox.width * observation.boundingBox.height)
            return area >= 0.002 ? sum + area : sum
        }

        return CategoryMeasurement(
            labels: CategorySignals.encode(labels: Array(labels)),
            textCoverage: min(1, coverage),
            isUtility: aesthetics?.isUtility,
            hasAnimal: hasAnimal,
            sharpness: sharpness,
            aestheticScore: aesthetics?.score
        )
    }

    private static func perform(
        _ requests: [VNRequest],
        on image: CGImage,
        label: String,
        cancellation: CancellationState
    ) throws {
        guard cancellation.activate(requests) else { throw CancellationError() }
        PhotoKitDiag.requestStarted("vision:\(label)")
        defer {
            cancellation.clear()
            PhotoKitDiag.requestFinished("vision:\(label)")
        }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        } catch {
            if cancellation.isCancelled { throw CancellationError() }
            throw error
        }
        try cancellation.check()
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var activeRequests: [VNRequest] = []

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func check() throws {
            if isCancelled || Task.isCancelled { throw CancellationError() }
        }

        func activate(_ requests: [VNRequest]) -> Bool {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                requests.forEach { $0.cancel() }
                return false
            }
            activeRequests = requests
            lock.unlock()
            return true
        }

        func clear() {
            lock.lock()
            activeRequests = []
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let requests = activeRequests
            lock.unlock()
            requests.forEach { $0.cancel() }
        }
    }
}
