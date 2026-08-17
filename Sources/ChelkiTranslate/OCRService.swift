import AppKit
@preconcurrency import Vision

enum OCRError: LocalizedError {
    case invalidImage
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "No pude leer esa imagen."
        case .noTextFound:  return "No encontré texto en la imagen."
        }
    }
}

/// Reconocimiento de texto en imágenes usando Vision (offline, incluido en macOS).
enum OCRService {

    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImageForOCR() else { throw OCRError.invalidImage }
        return try await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = assemble(observations)
                if text.isEmpty {
                    continuation.resume(throwing: OCRError.noTextFound)
                } else {
                    continuation.resume(returning: text)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [Language.spanish.ocrIdentifier,
                                            Language.english.ocrIdentifier]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reordena las líneas de arriba hacia abajo y une las que pertenecen al mismo párrafo.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines = observations
            .compactMap { obs -> (text: String, box: CGRect)? in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (text, obs.boundingBox)
            }
            // Vision usa coordenadas normalizadas con el origen abajo a la izquierda.
            .sorted { lhs, rhs in
                if abs(lhs.box.midY - rhs.box.midY) > 0.012 {
                    return lhs.box.midY > rhs.box.midY
                }
                return lhs.box.minX < rhs.box.minX
            }

        var result = ""
        var previousBox: CGRect?

        for line in lines {
            defer { previousBox = line.box }

            guard let previous = previousBox else {
                result = line.text
                continue
            }

            let verticalGap = previous.minY - line.box.maxY
            let lineHeight = max(line.box.height, 0.001)

            if verticalGap > lineHeight * 0.9 {
                result += "\n\n"                       // párrafo nuevo
            } else if result.hasSuffix("-") {
                result.removeLast()                    // palabra cortada con guion
            } else {
                result += " "
            }
            result += line.text
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NSImage {
    /// CGImage con la resolución real del bitmap (no la lógica), ideal para OCR.
    func cgImageForOCR() -> CGImage? {
        if let tiff = tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return cg
        }
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
