import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKeyManager?
    private let model = TranslatorModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "translate",
                                   accessibilityDescription: "Traductor")
                ?? NSImage(systemSymbolName: "character.bubble",
                           accessibilityDescription: "Traductor")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Traductor  ·  ⌥⌘T"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // El panel siempre en oscuro: el vidrio se ve mucho mejor así.
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(model)
        )

        // Mientras macOS descarga un idioma muestra su propio diálogo encima:
        // fijamos el panel para que no se cierre y cancele la sesión.
        model.$keepOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] keepOpen in
                self?.popover.behavior = keepOpen ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        hotKey = HotKeyManager { [weak self] in
            self?.toggle()
        }

        if ProcessInfo.processInfo.environment["CHELKI_SELFTEST"] == "1" {
            runSelfTest()
        }
    }

    /// Comprobación de humo: detección, cambio automático de sentido,
    /// traducción y corrección gramatical. Reporta por stderr.
    private func runSelfTest() {
        show()

        Task { @MainActor in
            @MainActor func log(_ line: String) {
                FileHandle.standardError.write(Data("SELFTEST \(line)\n".utf8))
            }

            @MainActor func translate(_ text: String, pinnedSource: Language?) async -> String {
                model.clear()
                model.sourceLanguage = pinnedSource
                model.inputText = text
                model.translate()
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(400))
                    if !model.outputText.isEmpty { return model.outputText }
                }
                return "«sin resultado: \(model.status.message ?? "?")»"
            }

            // 1. Idioma fijado en español, pero el texto llega en inglés.
            var out = await translate("Hey, can you send me the report before noon?",
                                      pinnedSource: .spanish)
            log("fijado=ES texto=EN → detectó \(model.effectiveSource.shortName), "
                + "traduce a \(model.effectiveTarget.shortName): \(out)")

            // 2. Idioma fijado en inglés, pero el texto llega en español.
            out = await translate("Oye, ¿me puedes enviar el informe antes del mediodía?",
                                  pinnedSource: .english)
            log("fijado=EN texto=ES → detectó \(model.effectiveSource.shortName), "
                + "traduce a \(model.effectiveTarget.shortName): \(out)")

            // 3. Corrección gramatical.
            log("modelo on-device: \(GrammarService.isModelAvailable ? "disponible" : "no disponible")")
            for text in ["oy fui al banko y no avia nadie atendiendo por que era feriado",
                         "i dont know if he have finish the report yesterday"] {
                if let correction = await GrammarService.correct(text, language: LanguageDetector.detect(text)?.language ?? .spanish) {
                    log("corrigió [\(correction.engine)] → \(correction.text)")
                } else {
                    log("corrigió → «sin cambios»")
                }
            }

            NSApp.terminate(nil)
        }
    }

    // MARK: - Interacción con el ícono

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let launch = NSMenuItem(title: "Abrir al iniciar sesión",
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.target = self
        launch.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "Traductor · ⌥⌘T para abrir",
                               action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Mostrar / ocultar

    func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }

    private func show() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.popoverDidOpen()
    }

    nonisolated func popoverShouldClose(_ popover: NSPopover) -> Bool {
        MainActor.assumeIsolated { !model.keepOpen }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.popoverDidClose() }
    }
}
