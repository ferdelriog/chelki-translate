import AppKit
import FoundationModels

/// Salida estructurada del modelo.
///
/// Pedir el texto "a secas" no basta: el modelo antepone cosas como
/// «¡Claro! Aquí tienes el texto corregido:» pese a prohibírselo. Con un tipo
/// generado el framework devuelve sólo el campo que pedimos.
@available(macOS 26.0, *)
@Generable
struct CorrectedText {
    @Guide(description: "El texto corregido y nada más. Sin preámbulos ni comentarios.")
    var texto: String
}

/// Corrección de ortografía y gramática, siempre en el equipo del usuario.
///
/// Primero intenta el modelo on-device de Apple Intelligence; si no está
/// disponible cae al corrector ortográfico que trae macOS desde siempre.
enum GrammarService {

    enum Engine {
        case appleIntelligence
        case spellChecker
    }

    struct Correction: Equatable {
        let text: String
        let engine: Engine
    }

    /// ¿Hay modelo on-device listo para usar?
    static var isModelAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// Devuelve el texto corregido, o `nil` si no hay nada que corregir.
    static func correct(_ text: String, language: Language) async -> Correction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            if let corrected = await correctWithModel(trimmed, language: language) {
                return differs(corrected, from: trimmed)
                    ? Correction(text: corrected, engine: .appleIntelligence)
                    : nil
            }
        }

        let corrected = correctWithSpellChecker(trimmed, language: language)
        return differs(corrected, from: trimmed)
            ? Correction(text: corrected, engine: .spellChecker)
            : nil
    }

    // MARK: - Apple Intelligence (on-device)

    @available(macOS 26.0, *)
    private static func correctWithModel(_ text: String, language: Language) async -> String? {
        let languageName = language == .spanish ? "español" : "inglés"

        // Instrucciones deliberadamente breves: con una lista larga de reglas el
        // modelo termina devolviendo las propias reglas como si fueran el texto.
        let instructions = """
        Corriges ortografía, tildes, puntuación, mayúsculas y concordancia en \
        \(languageName). No reformules ni traduzcas: conserva las palabras del autor \
        y arregla sólo lo que esté mal escrito. Respeta las tildes que ya estén bien \
        puestas. No agregues ni quites palabras. Si el texto ya está correcto, \
        devuélvelo idéntico.
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.1)
            // Delimitar el texto evita que el modelo confunda las instrucciones
            // con lo que tiene que corregir.
            let response = try await session.respond(to: "Texto a corregir:\n\(text)",
                                                     generating: CorrectedText.self,
                                                     options: options)
            let result = clean(response.content.texto)
            // Red de seguridad por si el modelo divaga o filtra el prompt.
            guard !result.isEmpty, isPlausible(result, original: text) else { return nil }
            return result
        } catch {
            return nil
        }
    }

    /// Descarta respuestas donde el modelo se salió del guion (resumió o divagó).
    private static func isPlausible(_ corrected: String, original: String) -> Bool {
        let ratio = Double(corrected.count) / Double(max(original.count, 1))
        return ratio > 0.5 && ratio < 2.0
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A veces el modelo envuelve la respuesta en comillas.
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where result.count > 2 {
            if result.first == open && result.last == close {
                result = String(result.dropFirst().dropLast())
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Corrector ortográfico de macOS (respaldo)

    private static func correctWithSpellChecker(_ text: String, language: Language) -> String {
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }

        let nsText = text as NSString
        var result = text
        var offset = 0
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.location < nsText.length {
            let misspelled = checker.checkSpelling(of: text,
                                                   startingAt: searchRange.location,
                                                   language: language.localeIdentifier,
                                                   wrap: false,
                                                   inSpellDocumentWithTag: tag,
                                                   wordCount: nil)
            guard misspelled.location != NSNotFound, misspelled.length > 0 else { break }

            if let guess = checker.guesses(forWordRange: misspelled,
                                           in: text,
                                           language: language.localeIdentifier,
                                           inSpellDocumentWithTag: tag)?.first {
                let adjusted = NSRange(location: misspelled.location + offset,
                                       length: misspelled.length)
                if let range = Range(adjusted, in: result) {
                    result.replaceSubrange(range, with: guess)
                    offset += guess.utf16.count - misspelled.length
                }
            }

            let next = misspelled.location + misspelled.length
            guard next < nsText.length else { break }
            searchRange = NSRange(location: next, length: nsText.length - next)
        }

        return result
    }

    // MARK: - Comparación

    /// Ignora diferencias que sólo son espacios en blanco.
    private static func differs(_ corrected: String, from original: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return normalized(corrected) != normalized(original)
    }
}
