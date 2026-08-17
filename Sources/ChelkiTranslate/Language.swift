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
        let raw = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard raw.count >= 2 else { return nil }

        // Un nombre propio o una URL no dicen nada del idioma, pero sí desvían al
        // reconocedor. Los quitamos ANTES de decidir; el texto que se traduce
        // sigue intacto.
        let cleaned = stripNoise(raw)
        let trimmed = cleaned.count >= 6 ? cleaned : raw

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

    /// Quita lo que no aporta idioma y sí confunde: encabezados de chat con el
    /// nombre de quien escribe, menciones, URLs, horas, emojis y código.
    ///
    /// Se usa **sólo** para detectar el idioma. Un «David» suelto hacía que un
    /// mensaje en inglés pegado desde Slack se tomara por español.
    private static func stripNoise(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)

        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }

            // «David Pérez  10:32», «David Pérez (él) 3:45 p. m.»
            if looksLikeChatHeader(trimmed) { return false }
            return true
        }

        var result = lines.joined(separator: "\n")

        let patterns = [
            "```[\\s\\S]*?```",              // bloques de código
            "`[^`]*`",                       // código en línea
            "https?://\\S+",                 // enlaces
            "\\bwww\\.\\S+",
            "\\S+@\\S+\\.\\S+",              // correos
            "[@#][\\w.-]+",                  // menciones y canales
            "<[^>]+>",                       // etiquetas y enlaces de Slack
            ":[a-z0-9_+-]+:",                // :emoji:
            "\\b\\d{1,2}:\\d{2}\\s*([ap]\\.?\\s?m\\.?)?", // horas
            "\\d+"                           // números sueltos
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern,
                                                 with: " ",
                                                 options: [.regularExpression, .caseInsensitive])
        }

        // Emojis y símbolos.
        result = String(result.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmoji && scalar.properties.isEmojiPresentation)
        })

        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Una línea corta hecha sólo de nombres propios, opcionalmente con una hora.
    private static func looksLikeChatHeader(_ line: String) -> Bool {
        let withoutTime = line.replacingOccurrences(
            of: "\\b\\d{1,2}:\\d{2}\\s*([ap]\\.?\\s?m\\.?)?",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let words = withoutTime.split(whereSeparator: { !$0.isLetter && $0 != "." }).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }

        // Todas las palabras empiezan en mayúscula: parece una firma, no una frase.
        let capitalized = words.allSatisfy { $0.first?.isUppercase == true }
        let hadTime = withoutTime.count < line.count
        return capitalized && (hadTime || words.count <= 3)
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
