import CoreGraphics
import CoreML
import Foundation

final class FaceNetEmbeddingEngine {
    static let inputSide = 160
    static let embeddingSize = 512

    private let model: Facenet6?

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? Facenet6(configuration: configuration)
    }

    func embedding(for image: CGImage) -> [Float]? {
        guard let model else { return nil }
        guard let pixels = rgbPixels(image) else { return nil }

        let count = pixels.count
        guard count == Self.inputSide * Self.inputSide * 3 else {
            return nil
        }

        let mean = pixels.reduce(0, +) / Float(count)

        var variance: Float = 0
        for value in pixels {
            let delta = value - mean
            variance += delta * delta
        }

        let std = sqrt(variance / Float(count))
        let adjustedStd = max(
            std,
            1 / sqrt(Float(count))
        )

        guard let input = try? MLMultiArray(
            shape: [
                1,
                NSNumber(value: Self.inputSide),
                NSNumber(value: Self.inputSide),
                3
            ],
            dataType: .float32
        ) else {
            return nil
        }

        for i in 0..<count {
            input[i] = NSNumber(
                value: (pixels[i] - mean) / adjustedStd
            )
        }

        guard let prediction = try? model.prediction(input: input) else {
            return nil
        }

        let output = prediction.embeddings
        guard output.count >= Self.embeddingSize else { return nil }

        var values = [Float]()
        values.reserveCapacity(Self.embeddingSize)

        for index in 0..<Self.embeddingSize {
            values.append(output[index].floatValue)
        }

        return Self.normalized(values)
    }

    static func cosineSimilarity(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }

        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0

        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }

        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return -1 }
        return dot / denominator
    }

    static func updatedCentroid(
        current: [Float],
        currentCount: Int,
        adding next: [Float]
    ) -> [Float] {
        guard current.count == next.count else { return current }

        let oldWeight = Float(max(currentCount, 1))
        var merged = [Float](repeating: 0, count: current.count)

        for index in current.indices {
            merged[index] = (
                current[index] * oldWeight +
                next[index]
            ) / (oldWeight + 1)
        }

        return normalized(merged)
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector {
            sum += value * value
        }

        let norm = sqrt(sum)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func rgbPixels(_ source: CGImage) -> [Float]? {
        let side = Self.inputSide
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var rgba = [UInt8](
            repeating: 0,
            count: side * side * bytesPerPixel
        )

        guard let context = CGContext(
            data: &rgba,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:
                CGImageAlphaInfo.noneSkipLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: side, height: side)
        )

        var rgb = [Float]()
        rgb.reserveCapacity(side * side * 3)

        for offset in stride(
            from: 0,
            to: rgba.count,
            by: bytesPerPixel
        ) {
            rgb.append(Float(rgba[offset]))
            rgb.append(Float(rgba[offset + 1]))
            rgb.append(Float(rgba[offset + 2]))
        }

        return rgb
    }
}
