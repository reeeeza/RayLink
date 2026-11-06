import SwiftUI

@main
struct V2SApp: App {
    @StateObject private var model = V2SViewModel()

    var body: some Scene {
        WindowGroup {
            V2SPrivacyGate(model: model) { V2SMainView(model: model) }
                .environment(\.locale, Locale(identifier: model.settings.languageCode ?? "en"))
                .environment(\.layoutDirection, ["fa", "ar"].contains(model.settings.languageCode ?? "en") ? .rightToLeft : .leftToRight)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1_080, height: 740)

        Settings {
            V2SPrivacyGate(model: model) { V2SSettingsView(model: model) }
                .environment(\.locale, Locale(identifier: model.settings.languageCode ?? "en"))
                .environment(\.layoutDirection, ["fa", "ar"].contains(model.settings.languageCode ?? "en") ? .rightToLeft : .leftToRight)
                .frame(minWidth: 640, minHeight: 720)
        }
    }
}
