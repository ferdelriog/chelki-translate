import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Atajo global ⌥⌘T

/// Registra un atajo global con Carbon. No requiere permisos de accesibilidad.
final class HotKeyManager {

    private static var shared: HotKeyManager?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        HotKeyManager.shared = self
        register()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyManager.shared?.action() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43484B54), id: 1) // 'CHKT'
        RegisterEventHotKey(UInt32(kVK_ANSI_T),
                            UInt32(cmdKey | optionKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }
}

// MARK: - Abrir al iniciar sesión

enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("No se pudo cambiar el arranque automático: \(error.localizedDescription)")
        }
    }
}

// MARK: - Lectura en voz alta

final class Speaker {

    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String, language: Language) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }
}
