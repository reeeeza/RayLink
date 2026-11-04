//
//  RayLinkApp.swift
//  V2Teh
//
//  Created by Reza Eskandari on 2026-08-30.
//

import SwiftUI

enum AppStrings {
    static func value(_ key: String) -> String {
        let selected = UserDefaults.standard.string(forKey: "v2s.interfaceLanguage") ?? "system"
        let language = selected == "system"
            ? (Bundle.main.preferredLocalizations.first ?? "en")
            : selected
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: [CVarArg]) -> String {
        String(format: value(key), arguments: arguments)
    }
}

@main
struct V2TehApp: App {
    init() { SubscriptionStore.prepareInstallation() }
    @AppStorage("v2s.interfaceLanguage") private var interfaceLanguage = "system"

    private var language: String {
        interfaceLanguage == "system"
            ? (Bundle.main.preferredLocalizations.first ?? "en")
            : interfaceLanguage
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, ["ar", "fa"].contains(language) ? .rightToLeft : .leftToRight)
        }
    }
}
