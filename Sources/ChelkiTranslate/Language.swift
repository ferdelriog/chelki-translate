import Foundation
import NaturalLanguage

/// Idiomas soportados por la app.
enum Language: String, CaseIterable, Identifiable, Codable {
    case spanish = "es"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "Inglés"
        }
    }

    var shortName: String {
        switch self {
        case .spanish: return "ES"
        case .english: return "EN"
        }
    }

    var flag: String {
        switch self {
        case .spanish: return "🇪🇸"
        case .english: return "🇺🇸"
        }
    }

    /// Identificador de locale usado por el framework Translation.
    var localeIdentifier: String {
        switch self {
        case .spanish: return "es-ES"
        case .english: return "en-US"
        }
    }

    /// Idiomas que pasamos a Vision para el OCR.
    var ocrIdentifier: String { localeIdentifier }

    var opposite: Language {
        self == .spanish ? .english : .spanish
    }
}

/// Resultado de la detección: idioma más probable y qué tan seguro estamos.
struct Detection: Equatable {
    let language: Language
    /// 0 = una moneda al aire · 1 = certeza.
    let confidence: Double

    /// A partir de aquí la detección pesa más que el idioma que hayas fijado a mano.
    var isReliable: Bool { confidence >= 0.60 }
}

/// Detección de idioma 100 % local con NaturalLanguage.
enum LanguageDetector {

    /// Devuelve el idioma detectado, limitado a los que soporta la app.
    /// Si no logra decidirse, devuelve `nil`.
    static func detect(_ text: String) -> Detection? {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard trimmed.count >= 2 else { return nil }

        // Señales inequívocas de español: ni nos molestamos en dudar.
        if trimmed.lowercased().contains(where: { "áéíóúñ¿¡ü".contains($0) }) {
            return Detection(language: .spanish, confidence: 0.97)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let spanish = hypotheses[.spanish] ?? 0
        let english = hypotheses[.english] ?? 0
        let total = spanish + english

        // El reconocedor no se moja: probamos con palabras muy frecuentes.
        guard total > 0.01 else {
            guard let hint = orthographicHint(trimmed) else { return nil }
            return Detection(language: hint, confidence: 0.70)
        }

        let winner: Language = spanish >= english ? .spanish : .english
        var confidence = max(spanish, english) / total

        // Empate técnico: dejamos que las palabras frecuentes desempaten.
        if confidence < 0.65, let hint = orthographicHint(trimmed) {
            return Detection(language: hint, confidence: hint == winner ? 0.80 : 0.70)
        }

        // En textos muy cortos el reconocedor se confía de más.
        let wordCount = trimmed.split(whereSeparator: { !$0.isLetter }).count
        if wordCount <= 2 { confidence *= 0.75 }

        return Detection(language: winner, confidence: confidence)
    }

    /// Pistas baratas: caracteres y palabras que sólo existen en español.
    private static func orthographicHint(_ text: String) -> Language? {
        let lower = text.lowercased()
        if lower.contains(where: { "áéíóúñ¿¡ü".contains($0) }) { return .spanish }

        let spanishWords: Set<String> = ["el", "la", "los", "las", "que", "de", "por",
                                         "para", "con", "una", "es", "pero", "como",
                                         "más", "esto", "esta", "hola", "gracias"]
        let englishWords: Set<String> = ["the", "and", "is", "are", "you", "this", "that",
                                         "with", "for", "have", "not", "was", "hello",
                                         "thanks", "please", "would", "should"]

        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return nil }

        let spanishHits = words.filter { spanishWords.contains($0) }.count
        let englishHits = words.filter { englishWords.contains($0) }.count

        if spanishHits == englishHits { return nil }
        return spanishHits > englishHits ? .spanish : .english
    }
}
