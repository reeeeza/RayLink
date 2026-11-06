import Foundation

enum V2SConnectionDuration {
    static func format(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

@MainActor
enum V2SLocalization {
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("fa", "فارسی"), ("ar", "العربية"),
        ("zh-Hans", "简体中文"), ("ru", "Русский"), ("es", "Español"),
        ("pt", "Português"), ("fr", "Français"), ("de", "Deutsch")
    ]
    static var currentLanguage = "en"
    static var isRightToLeft: Bool { ["fa", "ar"].contains(currentLanguage) }
    private struct Template { let key: String; let regex: NSRegularExpression }
    private static var templateCache: [String: [Template]] = [:]

    static func text(_ key: String, language: String? = nil, bundle: Bundle = .main) -> String {
        let code = language ?? currentLanguage
        guard code != "en", let path = bundle.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else { return key }
        let direct = localized.localizedString(forKey: key, value: key, table: nil)
        if direct != key { return direct }
        // Model messages remain English internally so comparisons/state logic
        // stay stable. Match their public format keys only at presentation time.
        for template in templates(in: bundle) {
            let range = NSRange(key.startIndex..., in: key)
            guard let match = template.regex.firstMatch(in: key, range: range) else { continue }
            let format = localized.localizedString(forKey: template.key, value: template.key, table: nil)
            let arguments: [CVarArg] = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: key).map { String(key[$0]) } ?? ""
            }
            return String(format: format, locale: Locale(identifier: code), arguments: arguments)
        }
        return key
    }

    private static func templates(in bundle: Bundle) -> [Template] {
        if let cached = templateCache[bundle.bundlePath] { return cached }
        guard let path = bundle.path(forResource: "en", ofType: "lproj"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [] }
        let result = values.keys.filter {
            $0.contains("%@") && $0.filter(\.isLetter).count > 4
        }.sorted { $0.count > $1.count }.compactMap { key -> Template? in
            let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return Template(key: key, regex: regex)
        }
        templateCache[bundle.bundlePath] = result
        return result
    }
}
