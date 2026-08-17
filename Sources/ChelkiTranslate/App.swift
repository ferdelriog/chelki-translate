import SwiftUI

@main
struct ChelkiTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // La app vive sólo en la barra de menús (LSUIElement = true).
        // Esta escena existe únicamente para satisfacer el protocolo App.
        Settings { EmptyView() }
    }
}
