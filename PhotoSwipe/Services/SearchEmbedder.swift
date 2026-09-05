import Accelerate
import CoreGraphics
@preconcurrency import CoreML
import Foundation

/// Lazily runs the two locally-installed MobileCLIP S2 towers. Model files are
/// deliberately optional: resource checks do no Core ML work, and a build
/// without research artifacts keeps Search unavailable rather than broken.
final class SearchEmbedder: @unchecked Sendable {
    static let dimension = 512
    static let imageSide = 256
    static let embeddingByteCount = dimension * MemoryLayout<Float16>.size

    enum Availability: Equatable {
        case ready
        case missingImageModel
        case missingTextModel
        case missingTokenizer
        case missingProvenance
    }

    enum Error: LocalizedError {
        case unavailable(Availability)
        case incompatibleModel(String)
        case inferenceFailed(String)
        case invalidEmbedding

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                switch reason {
                case .ready: "Search is available."
                case .missingImageModel: "The MobileCLIP image model is not installed."
                case .missingTextModel: "The MobileCLIP text model is not installed."
                case .missingTokenizer: "The CLIP tokenizer resources are not installed."
                case .missingProvenance: "The MobileCLIP provenance file is not installed."
                }
            case .incompatibleModel(let detail): "The installed MobileCLIP model is incompatible: \(detail)"
            case .inferenceFailed(let detail): "MobileCLIP inference failed: \(detail)"
            case .invalidEmbedding: "MobileCLIP produced an invalid embedding."
            }
        }
    }

    private let bundle: Bundle
    private let imageTower: Tower
    private let textTower: Tower
    private let tokenizer: LockedTokenizer

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        imageTower = Tower(kind: .image, bundle: bundle)
        textTower = Tower(kind: .text, bundle: bundle)
        tokenizer = LockedTokenizer(bundle: bundle)
    }

    /// Does not load, compile, or instantiate a model. This is safe to call
    /// from the Search tab and Settings gate.
    var availability: Availability { Self.availability(in: bundle) }

    static func availability(in bundle: Bundle = .main) -> Availability {
        guard modelURL(named: "MobileCLIPS2Image", in: bundle) != nil else { return .missingImageModel }
        guard modelURL(named: "MobileCLIPS2Text", in: bundle) != nil else { return .missingTextModel }
        guard bundle.url(forResource: "clip-vocab", withExtension: "json") != nil,
              bundle.url(forResource: "clip-merges", withExtension: "txt") != nil else {
            return .missingTokenizer
        }
        // Without the fingerprint the scan would silently skip embeddings
        // and every query would return nothing.
        guard bundle.url(forResource: "mobileclip-provenance", withExtension: "json") != nil else {
            return .missingProvenance
        }
        return .ready
    }

    /// Encodes a photo as exactly 1,024 little-endian Float16 bytes.
    func imageEmbedding(for image: CGImage) async throws -> Data {
        try Task.checkCancellation()
        guard availability == .ready else { throw Error.unavailable(availability) }
        let input = try Self.imageInput(from: image)
        let vector = try await imageTower.predict(input)
        try Task.checkCancellation()
        return try Self.float16Data(for: vector)
    }

    /// Text has a dedicated worker, so a photo backlog never delays queries.
    func textEmbedding(for text: String) async throws -> [Float] {
        try Task.checkCancellation()
        guard availability == .ready else { throw Error.unavailable(availability) }
        let ids = try tokenizer.encode(text)
        let input = try Self.textInput(ids)
        let vector = try await textTower.predict(input)
        try Task.checkCancellation()
        return vector
    }

    static func float16Data(for vector: [Float]) throws -> Data {
        guard vector.count == dimension else { throw Error.invalidEmbedding }
        var output = Data(capacity: embeddingByteCount)
        for value in vector {
            let bits = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: bits) { output.append(contentsOf: $0) }
        }
        return output
    }

    static func decodeFloat16(_ data: Data) -> [Float]? {
        guard data.count == embeddingByteCount else { return nil }
        return data.withUnsafeBytes { bytes in
            let words = bytes.bindMemory(to: UInt16.self)
            guard words.count == dimension else { return nil }
            return words.map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
        }
    }

    /// The converter places this small provenance file beside the optional
    /// packages. Its immutable checkpoint hash is the persisted index key.
    var modelFingerprint: String? {
        guard let url = bundle.url(forResource: "mobileclip-provenance", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkpoint = values["checkpointSHA256"] as? String,
              let source = values["sourceCommit"] as? String,
              !checkpoint.isEmpty, !source.isEmpty else { return nil }
        return "\(source):\(checkpoint)"
    }

    func imageEmbeddingIfPossible(_ image: CGImage) async -> Data? {
        try? await imageEmbedding(for: image)
    }

    fileprivate static func modelURL(named name: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "mlmodelc")
            ?? bundle.url(forResource: name, withExtension: "mlpackage")
    }

    private static func imageInput(from image: CGImage) throws -> MLMultiArray {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw Error.inferenceFailed("image has no pixels") }
        let side = imageSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue
        ) else { throw Error.inferenceFailed("could not prepare RGB pixels") }
        context.interpolationQuality = .high
        let scale = max(CGFloat(side) / CGFloat(width), CGFloat(side) / CGFloat(height))
        let drawSize = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        context.draw(image, in: CGRect(
            x: (CGFloat(side) - drawSize.width) / 2,
            y: (CGFloat(side) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ))

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let values = array.dataPointer.bindMemory(to: Float.self, capacity: side * side * 3)
        for pixel in 0..<(side * side) {
            let rgba = pixel * 4
            values[pixel] = Float(pixels[rgba]) / 255
            values[side * side + pixel] = Float(pixels[rgba + 1]) / 255
            values[2 * side * side + pixel] = Float(pixels[rgba + 2]) / 255
        }
        return array
    }

    private static func textInput(_ tokens: [Int32]) throws -> MLMultiArray {
        guard tokens.count == CLIPTokenizer.contextLength else { throw Error.inferenceFailed("tokenizer output length") }
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        let values = array.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        values.initialize(from: tokens, count: tokens.count)
        return array
    }
}

private final class LockedTokenizer: @unchecked Sendable {
    private let bundle: Bundle
    private let lock = NSLock()
    private var result: Result<CLIPTokenizer, Swift.Error>?

    init(bundle: Bundle) { self.bundle = bundle }

    func encode(_ text: String) throws -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        if result == nil { result = Result { try CLIPTokenizer(bundle: bundle) } }
        return try result!.get().encode(text)
    }
}

private final class Tower: @unchecked Sendable {
    enum Kind { case image, text }

    private let kind: Kind
    private let bundle: Bundle
    private let queue: DispatchQueue
    private var loaded: Result<LoadedTower, Swift.Error>?

    init(kind: Kind, bundle: Bundle) {
        self.kind = kind
        self.bundle = bundle
        queue = DispatchQueue(label: "com.phototinder.PhotoSwipe.mobileclip.\(kind == .image ? "image" : "text")", qos: .userInitiated)
    }

    func predict(_ input: MLMultiArray) async throws -> [Float] {
        try Task.checkCancellation()
        let result: [Float] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.predictSynchronously(input)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func predictSynchronously(_ input: MLMultiArray) throws -> [Float] {
        if loaded == nil { loaded = Result { try load() } }
        let tower = try loaded!.get()
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [tower.inputName: MLFeatureValue(multiArray: input)]),
              let output = try? tower.model.prediction(from: provider),
              let array = output.featureValue(for: tower.outputName)?.multiArrayValue else {
            throw SearchEmbedder.Error.inferenceFailed("Core ML prediction")
        }
        guard array.dataType == .float32, array.count == SearchEmbedder.dimension else {
            throw SearchEmbedder.Error.incompatibleModel("output must be Float32 [1, 512]")
        }
        let values = Array(UnsafeBufferPointer(start: array.dataPointer.bindMemory(to: Float.self, capacity: array.count), count: array.count))
        var sum: Float = 0
        vDSP_svesq(values, 1, &sum, vDSP_Length(values.count))
        let norm = sqrt(sum)
        guard norm.isFinite, norm > 0, values.allSatisfy(\.isFinite) else { throw SearchEmbedder.Error.invalidEmbedding }
        var divisor = norm
        var normalized = [Float](repeating: 0, count: values.count)
        vDSP_vsdiv(values, 1, &divisor, &normalized, 1, vDSP_Length(values.count))
        return normalized
    }

    private func load() throws -> LoadedTower {
        let name = kind == .image ? "MobileCLIPS2Image" : "MobileCLIPS2Text"
        guard let source = SearchEmbedder.modelURL(named: name, in: bundle) else {
            throw SearchEmbedder.Error.unavailable(kind == .image ? .missingImageModel : .missingTextModel)
        }
        let url: URL
        if source.pathExtension == "mlmodelc" {
            url = source
        } else {
            do { url = try MLModel.compileModel(at: source) }
            catch { throw SearchEmbedder.Error.incompatibleModel("\(name) could not compile") }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model: MLModel
        do { model = try MLModel(contentsOf: url, configuration: configuration) }
        catch { throw SearchEmbedder.Error.incompatibleModel("\(name) could not load") }

        let expectedInput = kind == .image ? "image" : "tokens"
        guard let input = model.modelDescription.inputDescriptionsByName[expectedInput]?.multiArrayConstraint,
              let output = model.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint,
              model.modelDescription.inputDescriptionsByName.count == 1,
              model.modelDescription.outputDescriptionsByName.count == 1,
              output.dataType == .float32,
              output.shape.map(\ .intValue) == [1, SearchEmbedder.dimension] else {
            throw SearchEmbedder.Error.incompatibleModel("feature names or output contract")
        }
        let inputShape = kind == .image ? [1, 3, SearchEmbedder.imageSide, SearchEmbedder.imageSide] : [1, CLIPTokenizer.contextLength]
        let inputType: MLMultiArrayDataType = kind == .image ? .float32 : .int32
        guard input.dataType == inputType, input.shape.map(\ .intValue) == inputShape else {
            throw SearchEmbedder.Error.incompatibleModel("input contract")
        }
        return LoadedTower(model: model, inputName: expectedInput, outputName: "embedding")
    }
}

private struct LoadedTower {
    let model: MLModel
    let inputName: String
    let outputName: String
}
