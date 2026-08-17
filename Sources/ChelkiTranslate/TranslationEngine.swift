import Foundation
import Translation

// MARK: - Disponibilidad del traductor de macOS

enum AppleTranslation {

    enum Status {
        case installed      // el idioma ya está descargado: traduce sin conexión
        case supported      // hay que descargarlo (macOS pide confirmación)
        case unsupported    // el par de idiomas no está disponible
    }

    static func status(from source: Language, to target: Language) async -> Status {
        let availability = LanguageAvailability()
        let result = await availability.status(
            from: Locale.Language(identifier: source.localeIdentifier),
            to: Locale.Language(identifier: target.localeIdentifier)
        )
        switch result {
        case .installed:      return .installed
        case .supported:      return .supported
        case .unsupported:    return .unsupported
        @unknown default:     return .unsupported
        }
    }
}

/// Errores del traductor.
///
/// Esta app no tiene ningún respaldo por internet a propósito: si el idioma no
/// está descargado no traducimos, en lugar de mandar tu texto a un tercero.
enum TranslationError: LocalizedError {
    case languageNotDownloaded
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .languageNotDownloaded:
            return "Falta descargar el idioma. Pulsa «Descargar idiomas» aquí arriba."
        case .downloadFailed:
            return "No se pudo descargar el idioma. También puedes hacerlo en Ajustes ▸ General ▸ Idioma y región."
        }
    }
}
