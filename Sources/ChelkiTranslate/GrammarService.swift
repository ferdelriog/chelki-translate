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

    /// Traza de diagnóstico, sólo con CHELKI_DEBUG=1.
    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["CHELKI_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("GRAMMAR \(message)\n".utf8))
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
            // El modelo falla de vez en cuando (devuelve vacío, o la sesión se
            // cancela). Reintentamos antes de darlo por perdido.
            for attempt in 1...3 {
                if Task.isCancelled { return nil }

                if let corrected = await correctWithModel(trimmed, language: language) {
                    return differs(corrected, from: trimmed)
                        ? Correction(text: corrected, engine: .appleIntelligence)
                        : nil
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(250 * attempt))
                }
            }

            // Teniendo Apple Intelligence disponible, preferimos no proponer nada
            // antes que ofrecer lo del corrector ortográfico: éste va palabra por
            // palabra y convierte "validndo" en "valiendo".
            debugLog("el modelo no respondió tras 3 intentos; no proponemos corrección")
            return nil
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
            guard !result.isEmpty, isPlausible(result, original: text) else {
                debugLog("descartada por el filtro: [\(result)]")
                return nil
            }
            return result
        } catch {
            debugLog("el modelo falló: \(error)")
            return nil
        }
    }

    /// Descarta respuestas donde el modelo se salió del guion: divagó, resumió,
    /// contestó otra cosa o filtró sus propias instrucciones.
    ///
    /// Comparar sólo la longitud no basta — un texto igual de largo pero sin
    /// relación pasaba el filtro. Aquí exigimos además que la mayoría de las
    /// palabras del original sobrevivan en la corrección.
    private static func isPlausible(_ corrected: String, original: String) -> Bool {
        let ratio = Double(corrected.count) / Double(max(original.count, 1))
        guard ratio > 0.5, ratio < 2.0 else { return false }

        let originalWords = words(of: original)
        guard !originalWords.isEmpty else { return false }
        let correctedWords = words(of: corrected)

        // Una corrección cambia letras sueltas ("banko" → "banco"), así que no
        // exigimos igualdad: basta con que exista una palabra parecida.
        let survivors = originalWords.filter { word in
            correctedWords.contains { areSimilar($0, word) }
        }.count

        return Double(survivors) / Double(originalWords.count) >= 0.6
    }

    private static func words(of text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// Dos palabras son «la misma» si difieren en poco: una tilde, una letra
    /// cambiada, una que falta. Cubre "sto"→"esto", "banko"→"banco",
    /// "validndo"→"validando" y "corector"→"corrector".
    private static func areSimilar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }

        let longest = max(lhs.count, rhs.count)
        if abs(lhs.count - rhs.count) > 3 { return false }

        // Palabras cortas admiten un error; las largas, hasta un tercio.
        let tolerance = max(1, longest / 3)
        return editDistance(Array(lhs), Array(rhs), limit: tolerance) <= tolerance
    }

    /// Distancia de Levenshtein con corte temprano: en cuanto una fila entera
    /// supera el límite, la respuesta ya no puede bajar de ahí.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character], limit: Int) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            var rowBest = current[0]

            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                rowBest = min(rowBest, current[j])
            }

            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }

        return previous[rhs.count]
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
