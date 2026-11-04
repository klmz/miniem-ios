import Foundation
import Security

/// Configuration and the card cache, shared by the app and the widget through the
/// `group.nl.klmz.miniem` App Group. The long-lived token lives in the Keychain, in the
/// same group, readable after first unlock so the widget can use it on a locked phone.
enum Store {
    static let appGroup = "group.nl.klmz.miniem"

    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    private static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var cacheURL: URL { container.appendingPathComponent("ha-cards.json") }

    // MARK: configuration

    static var url: String? {
        get { defaults.string(forKey: "url") }
        set { defaults.set(newValue, forKey: "url") }
    }

    static var deviceId: String {
        if let id = defaults.string(forKey: "device_id") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "device_id")
        return id
    }

    static var registered: String? {
        get { defaults.string(forKey: "registered") }
        set { defaults.set(newValue, forKey: "registered") }
    }

    static var pushToken: String? {
        get { defaults.string(forKey: "push_token") }
        set { defaults.set(newValue, forKey: "push_token") }
    }

    static var lastSeenAt: Int64 {
        get { Int64(defaults.double(forKey: "last_seen_at")) }
        set { defaults.set(Double(newValue), forKey: "last_seen_at") }
    }

    static var configured: Bool { url != nil && token != nil }

    /// `homeassistant.example.ts.net/` → `https://homeassistant.example.ts.net`; plain http refused.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty || text.contains(" ") { return nil }
        if text.contains("://") {
            guard text.hasPrefix("https://") else { return nil }
        } else {
            text = "https://" + text
        }
        let host = text.dropFirst("https://".count).split(separator: "/").first.map(String.init) ?? ""
        let bare = host.split(separator: ":").first.map(String.init) ?? ""
        guard bare.contains("."), !bare.hasPrefix("."), !bare.hasSuffix(".") else { return nil }
        return text
    }

    // MARK: token (Keychain)

    private static let tokenQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "nl.klmz.miniem.ha",
        kSecAttrAccount as String: "long-lived-token",
        kSecAttrAccessGroup as String: appGroup,
    ]

    static var token: String? {
        var query = tokenQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ token: String?) -> Bool {
        SecItemDelete(tokenQuery as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return true }
        var item = tokenQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        setToken(nil)
        for key in ["url", "registered", "last_seen_at"] { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: cacheURL)
        clearWidgetValues()
    }

    // MARK: cards

    static func cachedCards() -> [Card] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return CardParser.parseList(data) ?? []
    }

    static func writeCache(_ data: Data) {
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func removeFromCache(cardId: String) {
        guard let data = try? Data(contentsOf: cacheURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = root["cards"] as? [[String: Any]] else { return }
        root["cards"] = cards.filter { $0["id"] as? String != cardId }
        if let updated = try? JSONSerialization.data(withJSONObject: root) { writeCache(updated) }
    }

    // MARK: widget input values
    // A widget cannot hold state of its own, so a toggle flipped on the widget is written
    // here and sent along with the next button press on that card.

    static func widgetValues(cardId: String) -> [String: JSONValue] {
        guard let data = defaults.data(forKey: "widget_values"),
              let all = try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data) else { return [:] }
        return all[cardId] ?? [:]
    }

    static func setWidgetValue(cardId: String, key: String, value: JSONValue) {
        var all: [String: [String: JSONValue]] = [:]
        if let data = defaults.data(forKey: "widget_values"),
           let decoded = try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data) { all = decoded }
        all[cardId, default: [:]][key] = value
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: "widget_values") }
    }

    static func clearWidgetValues() { defaults.removeObject(forKey: "widget_values") }
}
