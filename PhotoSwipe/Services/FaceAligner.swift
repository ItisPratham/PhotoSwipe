import CoreGraphics
import CoreML
import Foundation
import Vision

/// Turns a detected face into the exact tensor AdaFace IR-50 expects: a
/// 5-point-aligned 112×112 crop, channel order **BGR**, each pixel normalized
/// `(px−127.5)/128`, shaped `[1, 3, 112, 112]` (NCHW Float32).
///
/// Alignment is non-negotiable: AdaFace (like ArcFace) was trained on faces
/// warped to the canonical ArcFace 5-point template, so a raw bounding-box
/// crop produces garbage embeddings. We extract the 5 landmarks (eyes, nose,
/// mouth corners) from Vision, fit a 2-D similarity transform (rotation +
/// uniform scale + translation) mapping them onto the template, and warp the
/// source image through it.
///
/// **Preprocessing contract** (must match convert_adaface.py exactly):
///   1. 5-landmark similarity-transform warp → 112×112
///   2. Channel order: **BGR**  (Blue = plane 0, Green = plane 1, Red = plane 2)
///   3. Normalization: `(pixel − 127.5) / 128`  → values in `[−1, 1]`
///   4. Feed as `MLMultiArray` shaped `[1, 3, 112, 112]`, Float32
///
/// **Coordinate system:** Vision uses origin **bottom-left**, y-up, in pixels.
/// The template is y-flipped to match, and the Core Graphics context agrees,
/// so no error-prone flips are needed at call sites. If you change one, change
/// all three.
enum FaceAligner {

    /// Canonical ArcFace/AdaFace 112×112 template in bottom-left coordinates.
    /// Order: [eye (smaller x), eye (larger x), nose, mouth (smaller x),
    /// mouth (larger x)] — same order the detected points are put in.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112 - 51.6963),
        CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366),
        CGPoint(x: 41.5493, y: 112 - 92.3655),
        CGPoint(x: 70.7299, y: 112 - 92.2041),
    ]

    private static let side = FaceEmbedder.inputSide  // 112

    /// Builds the aligned `[1,3,112,112]` BGR Float32 input tensor for
    /// AdaFace, or nil if landmarks are missing or the warp fails.
    static func alignedMultiArray(cgImage: CGImage,
                                  imageSize: CGSize,
                                  observation: VNFaceObservation) -> MLMultiArray? {
        guard let source = sourcePoints(for: observation, imageSize: imageSize),
              let transform = similarityTransform(from: source, to: template),
              let pixels = warp(cgImage: cgImage, imageSize: imageSize, transform: transform)
        else { return nil }
        return multiArray(fromRGBA: pixels)
    }

    /// DEBUG: renders the aligned 112×112 crop as a viewable `CGImage` using
    /// the exact same landmarks + warp as the embedding path.
    static func debugAlignedCGImage(cgImage: CGImage,
                                    imageSize: CGSize,
                                    observation: VNFaceObservation) -> CGImage? {
        guard let source = sourcePoints(for: observation, imageSize: imageSize),
              let transform = similarityTransform(from: source, to: template) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        return ctx.makeImage()
    }

    // MARK: - Landmarks → 5 ordered source points

    private static func sourcePoints(for observation: VNFaceObservation,
                                     imageSize: CGSize) -> [CGPoint]? {
        guard let lm = observation.landmarks else { return nil }

        // Eyes: prefer single-point pupils; fall back to eye-contour centroid.
        guard let eyeA = center(lm.leftPupil, imageSize) ?? center(lm.leftEye, imageSize),
              let eyeB = center(lm.rightPupil, imageSize) ?? center(lm.rightEye, imageSize),
              let nose = center(lm.nose, imageSize),
              let lips = lm.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 2
        else { return nil }

        // Sort by x so the order matches the template regardless of which
        // pupil Vision labeled "left" vs "right".
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        guard let mouthLeft = lips.min(by: { $0.x < $1.x }),
              let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }

        return [eyes[0], eyes[1], nose, mouthLeft, mouthRight]
    }

    /// Centroid of a landmark region in image pixels (bottom-left origin).
    private static func center(_ region: VNFaceLandmarkRegion2D?, _ imageSize: CGSize) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.pointsInImage(imageSize: imageSize)
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: - Similarity transform (least-squares, closed form)

    /// Least-squares 2-D similarity transform (uniform scale + rotation +
    /// translation) mapping `src` onto `dst`. Uses the same closed form as
    /// OpenCV's `estimateAffinePartial2D` — no SVD needed. Returns nil when
    /// the source points are degenerate (all coincident).
    private static func similarityTransform(from src: [CGPoint],
                                            to dst: [CGPoint]) -> CGAffineTransform? {
        let n = src.count
        guard n == dst.count, n > 0 else { return nil }

        let muSrc = centroid(src)
        let muDst = centroid(dst)

        var sumSrc2 = 0.0   // Σ |src − muSrc|²
        var a = 0.0         // Σ (src·dst) → scale·cosθ numerator
        var b = 0.0         // Σ (src × dst) → scale·sinθ numerator
        for i in 0..<n {
            let sx = Double(src[i].x - muSrc.x), sy = Double(src[i].y - muSrc.y)
            let dx = Double(dst[i].x - muDst.x), dy = Double(dst[i].y - muDst.y)
            sumSrc2 += sx * sx + sy * sy
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
        }
        guard sumSrc2 > 0 else { return nil }

        let c = a / sumSrc2   // scale·cosθ
        let d = b / sumSrc2   // scale·sinθ
        // p' = [[c, −d],[d, c]]·p + t, with t = muDst − M·muSrc.
        let tx = Double(muDst.x) - (c * Double(muSrc.x) - d * Double(muSrc.y))
        let ty = Double(muDst.y) - (d * Double(muSrc.x) + c * Double(muSrc.y))
        return CGAffineTransform(a: c, b: d, c: -d, d: c, tx: tx, ty: ty)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: - Warp + tensor packing

    /// Warps the source image into a 112×112 RGBA pixel buffer via the
    /// similarity transform. Core Graphics renders in a bottom-left context,
    /// matching Vision's coordinate space.
    private static func warp(cgImage: CGImage,
                             imageSize: CGSize,
                             transform: CGAffineTransform) -> [UInt8]? {
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: side * bytesPerRow)
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.concatenate(transform)
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
            return true
        }
        return success ? buffer : nil
    }

    /// Packs an RGBA 112×112 pixel buffer into a `[1,3,112,112]` Float32
    /// MLMultiArray with **BGR** channel order and `(px−127.5)/128`
    /// normalization — the exact input contract of AdaFace IR-50.
    private static func multiArray(fromRGBA buffer: [UInt8]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        ) else { return nil }
        let plane = side * side
        let bytesPerRow = side * 4
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        for y in 0..<side {
            let rowStart = y * bytesPerRow
            for x in 0..<side {
                let px = rowStart + x * 4
                // RGBA source buffer → BGR planes, normalized (px−127.5)/128
                let b = (Float(buffer[px + 2]) - 127.5) / 128.0  // Blue  → channel 0
                let g = (Float(buffer[px + 1]) - 127.5) / 128.0  // Green → channel 1
                let r = (Float(buffer[px + 0]) - 127.5) / 128.0  // Red   → channel 2
                let pos = y * side + x
                ptr[0 * plane + pos] = b
                ptr[1 * plane + pos] = g
                ptr[2 * plane + pos] = r
            }
        }
        return array
    }
}
