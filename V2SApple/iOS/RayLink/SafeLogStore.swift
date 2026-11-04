import Foundation

struct SafeLogEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var message: String
}

enum SafeLogStore {
    private static let key = "v2teh.safeLogs"
    private static let maximumEntries = 150

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConfiguration.appGroup)
    }

    static func load() -> [SafeLogEntry] {
        guard let data = defaults?.data(forKey: key),
              let entries = try? JSONDecoder().decode(
                [SafeLogEntry].self,
                from: data
              )
        else {
            return []
        }

        return entries.sorted { $0.date > $1.date }
    }

    static func append(_ message: String) {
        // Only call this with credential-free status text. Server addresses,
        // share links, subscription URLs and generated JSON never belong here.
        var entries = load()
        entries.insert(SafeLogEntry(message: message), at: 0)
        entries = Array(entries.prefix(maximumEntries))

        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults?.set(data, forKey: key)
    }

    static func removeAll() {
        defaults?.removeObject(forKey: key)
    }
}
