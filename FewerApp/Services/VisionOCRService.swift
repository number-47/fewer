import CoreGraphics
import FewerCore
import NaturalLanguage
import Vision

/// 端侧 Vision OCR。识别始终离开主线程，且不记录图像或识别文字。
actor VisionOCRService {
    static let shared = VisionOCRService()

    func recognize(image: CGImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            let blocks = (request.results ?? []).compactMap { observation -> OCRTextBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRTextBlock(
                    text: text,
                    confidence: candidate.confidence,
                    boundingBox: VNImageRectForNormalizedRect(
                        observation.boundingBox,
                        image.width,
                        image.height
                    ),
                    languageCode: Self.languageCode(for: text)
                )
            }
            return OCRResult(blocks: blocks)
        }.value
    }

    private nonisolated static func languageCode(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
