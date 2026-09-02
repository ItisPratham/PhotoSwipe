import Accelerate
import CoreML
import Foundation

/// Wraps the bundled AdaFace IR-50 Core ML model. Loads it lazily and *gated*:
/// if `FaceEmbedding.mlpackage` isn't in the bundle, `isAvailable` is false
/// and the People scan reports the model as missing instead of crashing.
/// Input/output feature names are read from the model description, so a
/// re-export with different names still works.
///
/// **Preprocessing contract** (FaceAligner handles this before calling here):
///   Input  — `[1, 3, 112, 112]` Float32, channel order **BGR**,
///             normalized `(px−127.5)/128` (values in `[−1, 1]`).
///   Output — 512-d embedding, returned **L2-normalized** so callers compare
///             by cosine similarity (a dot product on normalized vectors).
///
/// Do NOT change channel order or normalization without updating both
/// FaceAligner.swift and scripts/convert_adaface.py.
final class FaceEmbedder {
    static let shared = FaceEmbedder()

    /// Side length of the square aligned crop the model expects.
    static let inputSide = 112

    private let model: MLModel?
    private let inputName: String
    private let outputName: String

    var isAvailable: Bool { model != nil }

    private init() {
        if let loaded = Self.loadModel() {
            model = loaded.model
            inputName = loaded.inputName
            outputName = loaded.outputName
        } else {
            model = nil
            inputName = "input"
            outputName = "embedding"
        }
    }

    private static func loadModel() -> (model: MLModel, inputName: String, outputName: String)? {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let compiledURL: URL?
        if let already = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") {
            compiledURL = already
        } else if let package = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlpackage") {
            compiledURL = try? MLModel.compileModel(at: package)
        } else {
            compiledURL = nil
        }

        guard let url = compiledURL,
              let model = try? MLModel(contentsOf: url, configuration: config) else {
            return nil
        }
        let inName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let outName = model.modelDescription.outputDescriptionsByName.keys.first ?? "embedding"
        return (model, inName, outName)
    }

    /// Runs AdaFace IR-50 on a prepared `[1, 3, 112, 112]` BGR tensor
    /// (already normalized by FaceAligner) and returns the L2-normalized
    /// 512-d embedding, or nil if the model is unavailable or inference fails.
    func embed(_ input: MLMultiArray) -> [Float]? {
        guard let model,
              let provider = try? MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: input)]),
              let output = try? model.prediction(from: provider),
              let array = output.featureValue(for: outputName)?.multiArrayValue
        else { return nil }

        let count = array.count
        guard count > 0, array.dataType == .float32 else { return nil }
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        let vector = Array(UnsafeBufferPointer(start: ptr, count: count))
        return Self.l2normalized(vector)
    }

    /// L2-normalizes a vector so cosine similarity reduces to a dot product.
    static func l2normalized(_ v: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(v, 1, &sumOfSquares, vDSP_Length(v.count))
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
