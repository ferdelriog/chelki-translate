import AppKit
import SwiftUI
import Translation

/// Una petición concreta de traducción ya resuelta (idiomas definidos).
struct TranslationRequest: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let source: Language
    let target: Language
    /// Sólo dispara la descarga del idioma, sin traducir nada.
    var prepareOnly: Bool = false
}

enum TranslatorStatus: Equatable {
    case idle
    case readingImage
    case translating
    case downloadingLanguage
    case error(String)

    var message: String? {
        switch self {
        case .idle:                return nil
        case .readingImage:        return "Leyendo el texto de la imagen…"
        case .translating:         return "Traduciendo…"
        case .downloadingLanguage: return "Descargando el idioma (sólo la primera vez)…"
        case .error(let message):  return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .readingImage, .translating, .downloadingLanguage: return true
        default: return false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

@MainActor
final class TranslatorModel: ObservableObject {

    // Entrada / salida
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var attachedImage: NSImage?

    // Idiomas: `sourceLanguage == nil` significa detección automática.
    @Published var sourceLanguage: Language? {
        didSet { persist() }
    }
    @Published var targetLanguage: Language = .spanish {
        didSet { persist() }
    }

    // Preferencias
    @Published var autoReadClipboard: Bool = true { didSet { persist() } }

    /// Con la detección apagada mandas tú: el par de idiomas se queda como lo
    /// dejaste y sólo cambia con el botón ⇄ o pulsando los idiomas.
    @Published var autoDetectLanguage: Bool = true {
        didSet {
            persist()
            // Al pasar a manual congelamos el idioma que estuviera en uso,
            // para no quedar con el par sin definir.
            if !autoDetectLanguage, sourceLanguage == nil {
                sourceLanguage = detection?.language ?? .english
            }
            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translate()
            }
        }
    }
    @Published var autoCorrectGrammar: Bool = true {
        didSet {
            persist()
            if autoCorrectGrammar { requestCorrection() } else { suggestion = nil }
        }
    }

    /// Corrección propuesta para el texto de entrada (no se aplica sin permiso).
    @Published var suggestion: GrammarService.Correction?
    @Published private(set) var isCorrecting = false

    @Published private(set) var status: TranslatorStatus = .idle
    @Published private(set) var detection: Detection?
    @Published private(set) var activeRequest: TranslationRequest?

    /// Faltan los idiomas descargados para traducir sin conexión.
    @Published private(set) var needsDownload = false
    /// Mientras esté activo el panel no se cierra al perder el foco
    /// (macOS muestra su propio diálogo de descarga encima).
    @Published private(set) var keepOpen = false

    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    private var watchdog: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?

    init() {
        restore()
        Task { await refreshAvailability() }
    }

    // MARK: - Idiomas descargados

    func refreshAvailability() async {
        let forward = await AppleTranslation.status(from: .english, to: .spanish)
        let backward = await AppleTranslation.status(from: .spanish, to: .english)
        needsDownload = (forward != .installed) || (backward != .installed)
    }

    /// Pide a macOS que descargue los idiomas para poder traducir sin conexión.
    func downloadLanguages() {
        guard !status.isBusy else { return }
        keepOpen = true
        status = .downloadingLanguage
        activeRequest = TranslationRequest(text: "",
                                           source: .english,
                                           target: .spanish,
                                           prepareOnly: true)
    }

    // MARK: - Idiomas efectivos

    /// Idioma de origen real. La detección manda siempre que esté segura,
    /// aunque tengas un idioma fijado a mano: si pegas inglés teniendo
    /// español seleccionado, la app se cambia sola.
    var effectiveSource: Language {
        if autoDetectLanguage, let detection, detection.isReliable {
            return detection.language
        }
        return sourceLanguage ?? detection?.language ?? .english
    }

    /// Idioma de destino real. Nunca traducimos un idioma a sí mismo:
    /// si el texto ya viene en el idioma de destino, el par se invierte solo.
    var effectiveTarget: Language {
        effectiveSource == targetLanguage ? targetLanguage.opposite : targetLanguage
    }

    /// `true` cuando la detección pasó por encima de lo que habías elegido.
    var detectionOverrodeSelection: Bool {
        guard autoDetectLanguage,
              let detection, detection.isReliable,
              let sourceLanguage else { return false }
        return detection.language != sourceLanguage
    }

    var canTranslate: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.isBusy
    }

    /// Invierte la dirección de la traducción.
    ///
    /// En automático basta con intercambiar los textos: la detección deduce
    /// sola el nuevo sentido. En manual hay que dar vuelta el par a mano,
    /// porque nadie más lo va a hacer.
    func swapLanguages() {
        setLanguages(source: effectiveTarget, target: effectiveSource)

        guard !outputText.isEmpty else { return }

        let previousOutput = outputText
        outputText = inputText
        inputText = previousOutput
        suggestion = nil
        refreshDetection()
        translate()
    }

    /// Fija el par de idiomas a mano. Apaga la detección automática, porque
    /// si no volvería a pisar lo que acabas de elegir.
    func chooseLanguage(_ language: Language, asSource: Bool) {
        autoDetectLanguage = false
        if asSource {
            setLanguages(source: language, target: language.opposite)
        } else {
            setLanguages(source: language.opposite, target: language)
        }
        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translate()
        }
    }

    private func setLanguages(source: Language, target: Language) {
        sourceLanguage = source
        targetLanguage = target
    }

    // MARK: - Ciclo de vida del popover

    func popoverDidOpen() {
        guard autoReadClipboard else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount

        // Sólo autocompletamos si el campo está vacío: nunca pisamos lo que escribiste.
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteFromClipboard(silentIfEmpty: true)
    }

    func popoverDidClose() {
        if status.isError { status = .idle }
    }

    // MARK: - Entrada

    func refreshDetection() {
        detection = LanguageDetector.detect(inputText)
    }

    func clear() {
        inputText = ""
        outputText = ""
        attachedImage = nil
        detection = nil
        suggestion = nil
        status = .idle
        activeRequest = nil
        correctionTask?.cancel()
    }

    // MARK: - Corrección gramatical

    /// Pide una corrección para el texto actual. No modifica nada por su cuenta:
    /// deja la propuesta en `suggestion` para que la apliques si quieres.
    func requestCorrection() {
        correctionTask?.cancel()
        suggestion = nil

        guard autoCorrectGrammar else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return }

        let language = effectiveSource
        correctionTask = Task { [weak self] in
            guard let self else { return }
            self.isCorrecting = true
            defer { self.isCorrecting = false }

            let correction = await GrammarService.correct(text, language: language)
            guard !Task.isCancelled else { return }
            // El texto pudo cambiar mientras el modelo pensaba.
            guard self.inputText.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            self.suggestion = correction
        }
    }

    /// Reemplaza el texto de entrada por la versión corregida y retraduce.
    func applySuggestion() {
        guard let suggestion else { return }
        inputText = suggestion.text
        self.suggestion = nil
        refreshDetection()
        translate()
    }

    func dismissSuggestion() {
        suggestion = nil
        correctionTask?.cancel()
    }

    func pasteFromClipboard(silentIfEmpty: Bool = false) {
        let pasteboard = NSPasteboard.general
        lastClipboardChangeCount = pasteboard.changeCount

        if let image = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = image.first {
            load(image: first)
            return
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { $0.isFileURL && NSImage(contentsOf: $0) != nil }),
           let image = NSImage(contentsOf: url) {
            load(image: image)
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attachedImage = nil
            inputText = text
            refreshDetection()
            translate()
            return
        }

        if !silentIfEmpty {
            status = .error("No hay texto ni imagen en el portapapeles.")
        }
    }

    func load(image: NSImage) {
        attachedImage = image
        status = .readingImage
        outputText = ""

        Task {
            do {
                let text = try await OCRService.recognizeText(in: image)
                inputText = text
                refreshDetection()
                status = .idle
                translate()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func load(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else {
            status = .error("No pude abrir ese archivo como imagen.")
            return
        }
        load(image: image)
    }

    // MARK: - Traducción

    func translate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        refreshDetection()
        requestCorrection()

        let source = effectiveSource
        let target = effectiveTarget

        guard source != target else {
            outputText = inputText
            status = .idle
            return
        }

        status = .translating
        let request = TranslationRequest(text: text, source: source, target: target)
        activeRequest = request
        startWatchdog(for: request)
    }

    /// Si el framework de macOS no llega a entregarnos una sesión (par no disponible,
    /// descarga cancelada…), no dejamos la interfaz colgada esperando para siempre.
    private func startWatchdog(for request: TranslationRequest) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            guard self.activeRequest?.id == request.id, self.status == .translating else { return }
            self.status = .error(TranslationError.languageNotDownloaded.localizedDescription)
            await self.refreshAvailability()
        }
    }

    /// Ejecuta la petición pendiente con la sesión que entrega el framework de macOS.
    func perform(with session: TranslationSession) async {
        guard let request = activeRequest else { return }
        watchdog?.cancel()   // el framework respondió: ya no hace falta vigilar

        do {
            if request.prepareOnly {
                try await session.prepareTranslation()
                await refreshAvailability()
                keepOpen = false
                status = .idle
                activeRequest = nil
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translate()
                }
                return
            }

            if await AppleTranslation.status(from: request.source, to: request.target) != .installed {
                keepOpen = true
                status = .downloadingLanguage
                try await session.prepareTranslation()
                keepOpen = false
                await refreshAvailability()
                guard activeRequest?.id == request.id else { return }
                status = .translating
            }

            let response = try await session.translate(request.text)
            guard activeRequest?.id == request.id else { return }

            outputText = response.targetText
            status = .idle
        } catch is CancellationError {
            keepOpen = false
            // El usuario cambió de idioma mientras traducíamos: no es un error.
        } catch {
            keepOpen = false
            if request.prepareOnly {
                status = .error(TranslationError.downloadFailed.localizedDescription)
                activeRequest = nil
                return
            }
            status = .error(error.localizedDescription)
            await refreshAvailability()
        }
    }

    // MARK: - Salida

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(outputText, forType: .string)
        lastClipboardChangeCount = pasteboard.changeCount
    }

    func speakOutput() {
        guard !outputText.isEmpty else { return }
        Speaker.shared.speak(outputText, language: effectiveTarget)
    }

    // MARK: - Persistencia

    private enum Keys {
        static let source = "sourceLanguage"
        static let target = "targetLanguage"
        static let autoClipboard = "autoReadClipboard"
        static let autoCorrect = "autoCorrectGrammar"
        static let autoDetect = "autoDetectLanguage"
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(sourceLanguage?.rawValue ?? "auto", forKey: Keys.source)
        defaults.set(targetLanguage.rawValue, forKey: Keys.target)
        defaults.set(autoReadClipboard, forKey: Keys.autoClipboard)
        defaults.set(autoCorrectGrammar, forKey: Keys.autoCorrect)
        defaults.set(autoDetectLanguage, forKey: Keys.autoDetect)
    }

    private func restore() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Keys.source), raw != "auto" {
            sourceLanguage = Language(rawValue: raw)
        }
        if let raw = defaults.string(forKey: Keys.target), let language = Language(rawValue: raw) {
            targetLanguage = language
        }
        if defaults.object(forKey: Keys.autoClipboard) != nil {
            autoReadClipboard = defaults.bool(forKey: Keys.autoClipboard)
        }
        if defaults.object(forKey: Keys.autoCorrect) != nil {
            autoCorrectGrammar = defaults.bool(forKey: Keys.autoCorrect)
        }
        if defaults.object(forKey: Keys.autoDetect) != nil {
            autoDetectLanguage = defaults.bool(forKey: Keys.autoDetect)
        }
    }
}
