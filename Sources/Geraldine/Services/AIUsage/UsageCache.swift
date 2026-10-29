import Foundation

/// Small display summaries in the app's existing preferences domain. No raw
/// history records, credentials, or new retention policy.
enum UsageCache {
    static func load<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

enum UsageAge {
    static func text(_ date: Date?, now: Date) -> String {
        guard let date else { return "No successful update yet" }
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds.isFinite, seconds / 86400 < Double(Int.max) else { return "Update time unavailable" }
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "Updated \(Int(seconds / 3600)) hr ago" }
        return "Updated \(Int(seconds / 86400)) days ago"
    }
}
