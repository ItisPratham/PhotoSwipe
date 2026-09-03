import Accelerate
import CoreGraphics
import Foundation
import Vision

/// Cheap per-image quality signals computed on the scan's 256 px thumbnail.
/// Both are scale-dependent, so callers must always feed the same working
/// size (the duplicate scan does) and compare values only with each other.
enum ImageQuality {

    /// Sharpness = variance of a 3×3 Laplacian over the grayscale image. Blur
    /// flattens edges, so blurry photos score low. Nil if the image can't be
    /// rendered to grayscale.
    static func sharpness(of cgImage: CGImage) -> Float? {
        let width = cgImage.width, height = cgImage.height
        guard width >= 3, height >= 3 else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // Laplacian on interior pixels: 4·c − up − down − left − right.
        let innerWidth = width - 2, innerHeight = height - 2
        var laplacian = [Float](repeating: 0, count: innerWidth * innerHeight)
        gray.withUnsafeBufferPointer { g in
            var out = 0
            for y in 1..<(height - 1) {
                let row = y * width
                for x in 1..<(width - 1) {
                    let c = Int(g[row + x])
                    let sum = Int(g[row - width + x]) + Int(g[row + width + x])
                        + Int(g[row + x - 1]) + Int(g[row + x + 1])
                    laplacian[out] = Float(4 * c - sum)
                    out += 1
                }
            }
        }
        var mean: Float = 0
        var standardDeviation: Float = 0
        vDSP_normalize(laplacian, 1, nil, 1, &mean, &standardDeviation, vDSP_Length(laplacian.count))
        return standardDeviation * standardDeviation
    }

    /// Vision's overall aesthetics score (−1…1), iOS 18 and later. Nil on
    /// earlier systems or when the request fails.
    static func aestheticScore(of cgImage: CGImage) -> Float? {
        guard #available(iOS 18.0, *) else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        return observation.overallScore
    }
}
