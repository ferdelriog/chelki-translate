import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {

    @EnvironmentObject private var model: TranslatorModel

    @State private var configuration: TranslationSession.Configuration?
    @State private var isTargeted = false
    @State private var didCopy = false
    @State private var showingImporter = false
    @State private var debounce: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    // Paleta del vidrio oscuro. El panel fuerza apariencia oscura,
    // así que definimos los tonos a mano y no dependemos del sistema.
    private let accent = Color(red: 0.42, green: 0.66, blue: 1.0)
    private let glassFill = Color.white.opacity(0.07)
    private let glassStroke = Color.white.opacity(0.13)
    private let textPrimary = Color.white.opacity(0.94)
    private let textSecondary = Color.white.opacity(0.55)
    private let textTertiary = Color.white.opacity(0.35)
    private let success = Color(red: 0.35, green: 0.83, blue: 0.60)

    var body: some View {
        VStack(spacing: 0) {
            header
            languageBar
            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 10) {
                    if model.needsDownload { downloadBanner }
                    inputCard
                    if model.suggestion != nil { suggestionCard }
                    outputCard
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .frame(width: 420)
        .frame(minHeight: 480, maxHeight: 640)
        .background(panelBackground)
        .translationTask(configuration) { session in
            await model.perform(with: session)
        }
        .onChange(of: model.activeRequest) { _, request in
            guard let request else { return }
            configure(for: request)
        }
        .onChange(of: model.inputText) { _, _ in
            model.refreshDetection()
            scheduleAutoTranslate()
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                model.load(fileURL: url)
            }
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - Fondo

    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.55)
            LinearGradient(colors: [accent.opacity(0.22), .clear],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            LinearGradient(colors: [.clear, Color.black.opacity(0.25)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - Encabezado

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)

            Text("Traductor")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Menu {
                Toggle("Corregir gramática automáticamente", isOn: $model.autoCorrectGrammar)
                Toggle("Leer el portapapeles al abrir", isOn: $model.autoReadClipboard)
                Divider()
                Button("Abrir al iniciar sesión") { LoginItem.toggle() }
                Divider()
                Button("Salir") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opciones")
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: - Barra de idiomas

    private var languageBar: some View {
        HStack(spacing: 8) {
            languagePill(model.effectiveSource,
                         caption: sourceCaption,
                         highlighted: model.detection?.isReliable == true)

            Button {
                withAnimation(.snappy(duration: 0.22)) { model.swapLanguages() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(accent.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help("Invertir la dirección de la traducción")

            languagePill(model.effectiveTarget,
                         caption: "traducción",
                         highlighted: false)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 11)
        .animation(.snappy(duration: 0.22), value: model.effectiveSource)
    }

    private var sourceCaption: String {
        guard let detection = model.detection, detection.isReliable else { return "origen" }
        return model.detectionOverrodeSelection ? "detectado · cambiado solo" : "detectado"
    }

    private func languagePill(_ language: Language, caption: String, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(language.flag)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 1) {
                Text(language.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
                HStack(spacing: 3) {
                    if highlighted {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 7, weight: .bold))
                    }
                    Text(caption)
                        .font(.system(size: 9))
                }
                .foregroundStyle(highlighted ? accent : textSecondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? accent.opacity(0.16) : glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(highlighted ? accent.opacity(0.45) : glassStroke,
                                      lineWidth: 0.9)
                )
        )
    }

    // MARK: - Aviso de descarga

    private var downloadBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Traduce sin conexión")
                    .font(.system(size: 12, weight: .semibold))
                Text("Descarga los idiomas una sola vez y todo queda en tu Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.downloadLanguages()
                } label: {
                    Text("Descargar idiomas")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.status.isBusy)
                .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(accent.opacity(0.3), lineWidth: 0.9)
                )
        )
    }

    // MARK: - Entrada

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.inputText.isEmpty {
                    Text("Escribe, pega texto o suelta una imagen aquí")
                        .font(.system(size: 13))
                        .foregroundStyle(textTertiary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $model.inputText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .frame(minHeight: 88)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
            }

            if let image = model.attachedImage {
                imageChip(image)
            }

            HStack(spacing: 6) {
                smallButton("Pegar", icon: "doc.on.clipboard") {
                    model.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                smallButton("Imagen", icon: "photo") {
                    showingImporter = true
                }

                if model.isCorrecting {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).scaleEffect(0.65)
                        Text("revisando…")
                            .font(.system(size: 10))
                            .foregroundStyle(textSecondary)
                    }
                    .padding(.leading, 2)
                }

                Spacer()

                if !model.inputText.isEmpty {
                    smallButton("Limpiar", icon: "xmark") { model.clear() }
                }
            }
        }
        .padding(9)
        .background(card())
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
            }
        }
        .onDrop(of: [.image, .fileURL],
                isTargeted: $isTargeted.animation(.easeOut(duration: 0.15))) { providers in
            handleDrop(providers)
        }
    }

    private func imageChip(_ image: NSImage) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Texto leído de la imagen")
                    .font(.system(size: 11, weight: .medium))
                Text("Reconocimiento óptico en tu Mac")
                    .font(.system(size: 9))
                    .foregroundStyle(textSecondary)
            }

            Spacer()

            Button {
                model.attachedImage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.10))
        )
    }

    // MARK: - Corrección gramatical

    @ViewBuilder
    private var suggestionCard: some View {
        if let suggestion = model.suggestion {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                    Text("CORRECCIÓN EN \(model.effectiveSource.displayName.uppercased())")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                    Spacer()
                    Text(suggestion.engine == .appleIntelligence ? "Apple Intelligence" : "corrector de macOS")
                        .font(.system(size: 8))
                        .foregroundStyle(textSecondary)
                }
                .foregroundStyle(success)

                Text(suggestion.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Button {
                        withAnimation(.snappy) { model.applySuggestion() }
                    } label: {
                        Text("Usar corrección")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(success))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    smallButton("Ignorar", icon: "xmark") {
                        withAnimation(.snappy) { model.dismissSuggestion() }
                    }

                    Spacer()
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(success.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(success.opacity(0.3), lineWidth: 0.9)
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Salida

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9, weight: .semibold))
                Text(model.effectiveTarget.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                Spacer()
                if model.status.isBusy {
                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                }
            }
            .foregroundStyle(accent.opacity(0.9))

            Group {
                if model.outputText.isEmpty {
                    Text(model.status.isBusy ? "Un momento…" : "Aquí aparece la traducción")
                        .font(.system(size: 13))
                        .foregroundStyle(textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.outputText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 80, alignment: .topLeading)
            .padding(.horizontal, 1)

            if !model.outputText.isEmpty {
                HStack(spacing: 6) {
                    smallButton(didCopy ? "¡Copiado!" : "Copiar",
                                icon: didCopy ? "checkmark" : "doc.on.doc",
                                prominent: didCopy) {
                        copy()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                    smallButton("Escuchar", icon: "speaker.wave.2") {
                        model.speakOutput()
                    }

                    Spacer()
                }
            }
        }
        .padding(9)
        .background(card(tinted: true))
    }

    // MARK: - Pie

    private var footer: some View {
        HStack(spacing: 10) {
            statusLabel

            Spacer()

            Button {
                debounce?.cancel()
                model.translate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 11))
                    Text("Traducir").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!model.canTranslate)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let message = model.status.message {
            HStack(spacing: 5) {
                Image(systemName: statusIcon)
                    .font(.system(size: 9))
                Text(message)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(model.status.isError ? Color.orange : textSecondary)
        } else {
            Text("⌥⌘T abrir · ⌘⏎ traducir")
                .font(.system(size: 10))
                .foregroundStyle(textTertiary)
        }
    }

    private var statusIcon: String {
        switch model.status {
        case .error:               return "exclamationmark.triangle.fill"
        case .readingImage:        return "text.viewfinder"
        case .downloadingLanguage: return "arrow.down.circle"
        default:                   return "sparkles"
        }
    }

    // MARK: - Piezas reutilizables

    private func card(tinted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(tinted ? accent.opacity(0.13) : glassFill)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tinted ? accent.opacity(0.28) : glassStroke, lineWidth: 0.9)
            )
    }

    private func smallButton(_ title: String,
                             icon: String,
                             prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(prominent ? accent.opacity(0.25) : Color.white.opacity(0.09))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8))
            )
            .foregroundStyle(prominent ? accent : textPrimary.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Acciones

    private func configure(for request: TranslationRequest) {
        let source = Locale.Language(identifier: request.source.localeIdentifier)
        let target = Locale.Language(identifier: request.target.localeIdentifier)

        if configuration?.source == source && configuration?.target == target {
            configuration?.invalidate()   // mismo par de idiomas: reactiva la sesión
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func scheduleAutoTranslate() {
        debounce?.cancel()
        let text = model.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        debounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            model.translate()
        }
    }

    private func copy() {
        model.copyOutput()
        withAnimation(.snappy) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy) { didCopy = false }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                if let image = object as? NSImage {
                    Task { @MainActor in model.load(image: image) }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.load(fileURL: url) }
            }
            return true
        }

        return false
    }
}
