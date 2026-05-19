import Foundation
import SwiftUI
import Vision
import CoreML
import UIKit

// No direct dependency on MWDATCamera here — FaceProcessor works with UIImage inputs.

class FaceProcessor: ObservableObject {
    private let modelName: String
    private var mlModel: MLModel?
    private var inputName: String = "input"
    private var inputWidth: Int = 160
    private var inputHeight: Int = 160

    private var lastProcessDate = Date.distantPast
    private let minInterval: TimeInterval

    /// Callback invoked with embedding vector and the original cropped image.
    var onEmbedding: (([Float], UIImage) -> Void)?
    var onFaceDetected: (() -> Void)?
    var onNoFaceDetected: (() -> Void)?

    init(modelName: String = "FaceNet", throttleFPS: Double = 1.0) {
        self.modelName = modelName
        self.minInterval = 1.0 / max(1.0, throttleFPS)
        loadModel()
    }

    private func loadModel() {
        // Prefer requested FaceNet naming, then gracefully fall back to any bundled model artifact.
        let preferredModelNames = [modelName, "FaceNet"]
        let preferredURL = preferredModelNames.lazy.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: name, withExtension: "mlmodel")
            ?? Bundle.main.url(forResource: name, withExtension: "mlpackage")
        }.first

        let fallbackURL = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?.first
            ?? Bundle.main.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil)?.first
            ?? Bundle.main.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil)?.first

        let modelURL = preferredURL ?? fallbackURL

        guard let modelURL
        else {
            NSLog("[FaceProcessor] No FaceNet model found in bundle")
            return
        }

        do {
            let ml = try MLModel(contentsOf: modelURL)
            self.mlModel = ml

            if let first = ml.modelDescription.inputDescriptionsByName.first {
                self.inputName = first.key
                if let imgConstraint = first.value.imageConstraint {
                    self.inputWidth = Int(imgConstraint.pixelsWide)
                    self.inputHeight = Int(imgConstraint.pixelsHigh)
                }
            }
        } catch {
            NSLog("[FaceProcessor] Failed to load CoreML model: \(error)")
        }
    }

    func process(image: UIImage) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessDate) >= minInterval else { return }
        lastProcessDate = now

        guard let cg = image.cgImage else { return }

        let request = VNDetectFaceRectanglesRequest { [weak self] req, err in
            guard let self = self else { return }
            if let results = req.results as? [VNFaceObservation], !results.isEmpty {
                DispatchQueue.main.async {
                    self.onFaceDetected?()
                }
                for face in results {
                    self.handleFaceObservation(face, in: cg)
                }
            } else {
                DispatchQueue.main.async {
                    self.onNoFaceDetected?()
                }
            }
        }

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                NSLog("[FaceProcessor] VN request failed: \(error)")
            }
        }
    }

    /// Runs FaceNet embedding on a pre-cropped face image.
    func embedding(from faceImage: UIImage) async -> [Float]? {
        guard let mlModel = mlModel else { return nil }
        guard let resized = faceImage.resized(to: CGSize(width: inputWidth, height: inputHeight)) else { return nil }
        guard let pixelBuffer = resized.toCVPixelBuffer() else { return nil }

        return await Task.detached(priority: .userInitiated) { [inputName] in
            do {
                let inputValue = MLFeatureValue(pixelBuffer: pixelBuffer)
                let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputValue])
                let out = try mlModel.prediction(from: provider)

                if let feature = out.featureValue(for: out.featureNames.first ?? ""),
                   let ma = feature.multiArrayValue {
                    return Self.floatArray(from: ma)
                }

                for name in out.featureNames {
                    if let f = out.featureValue(for: name), let ma = f.multiArrayValue {
                        return Self.floatArray(from: ma)
                    }
                }
                return nil
            } catch {
                NSLog("[FaceProcessor] MLModel prediction failed: \(error)")
                return nil
            }
        }.value
    }

    private func handleFaceObservation(_ face: VNFaceObservation, in cgImage: CGImage) {
        let boundingBox = face.boundingBox
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var rect = CGRect(
            x: boundingBox.origin.x * width,
            y: (1 - boundingBox.origin.y - boundingBox.size.height) * height,
            width: boundingBox.size.width * width,
            height: boundingBox.size.height * height
        )
        rect = rect.insetBy(dx: -10, dy: -10)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = cgImage.cropping(to: rect) else { return }
        let uiImage = UIImage(cgImage: cropped)

        // Preprocess: resize to model input and create CVPixelBuffer
        guard let mlModel = mlModel else { return }
        guard let resized = uiImage.resized(to: CGSize(width: inputWidth, height: inputHeight)) else { return }
        guard let pixelBuffer = resized.toCVPixelBuffer() else { return }

        // Create feature provider and run prediction
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inputValue = MLFeatureValue(pixelBuffer: pixelBuffer)
                let provider = try MLDictionaryFeatureProvider(dictionary: [self.inputName: inputValue])
                let out = try mlModel.prediction(from: provider)
                // find first MLMultiArray in outputs
                if let feature = out.featureValue(for: out.featureNames.first ?? "") {
                    if let ma = feature.multiArrayValue {
                        let vec = Self.floatArray(from: ma)
                        DispatchQueue.main.async {
                            self.onEmbedding?(vec, uiImage)
                        }
                        return
                    }
                }
                // If not found, scan all outputs
                for name in out.featureNames {
                    if let f = out.featureValue(for: name), let ma = f.multiArrayValue {
                        let vec = Self.floatArray(from: ma)
                        DispatchQueue.main.async {
                            self.onEmbedding?(vec, uiImage)
                        }
                        return
                    }
                }
            } catch {
                NSLog("[FaceProcessor] MLModel prediction failed: \(error)")
            }
        }
    }

    private static func floatArray(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = Float(truncating: multiArray[i])
        }
        return result
    }
}

// MARK: - UIImage helpers
extension UIImage {
    func resized(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    func toCVPixelBuffer() -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let width = Int(size.width)
        let height = Int(size.height)
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        let pxdata = CVPixelBufferGetBaseAddress(pb)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pxdata, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: rgbColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return nil
        }

        guard let cgImage = cgImage else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
