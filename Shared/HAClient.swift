import Foundation

/// The phone's side of the Miniem integration's HTTP API (see docs/home-assistant.md in
/// miniem-android). Never throws: every call answers with a problem string or nil.
enum HAClient {
    static let schemaVersion = 1

    struct Failure: Error { let message: String }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Result<Data, Failure> {
        guard let base = Store.url, let token = Store.token else { return .failure(Failure(message: "Not connected.")) }
        guard let url = URL(string: base + path), url.scheme == "https" else { return .failure(Failure(message: "Not an https address.")) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .success(data)
            case 401, 403: return .failure(Failure(message: "Home Assistant refused the token."))
            case 404: return .failure(Failure(message: "The Miniem integration is not installed in Home Assistant."))
            default: return .failure(Failure(message: "Home Assistant answered \(status)."))
            }
        } catch {
            return .failure(Failure(message: "Home Assistant is not reachable (\(error.localizedDescription))."))
        }
    }

    /// Tells Home Assistant where to push to; skipped when nothing changed since last time.
    static func register(force: Bool = false) async -> String? {
        guard let url = Store.url, Store.token != nil else { return nil }
        let fingerprint = "\(url)|\(Store.pushToken ?? "")"
        if !force && Store.registered == fingerprint { return nil }
        let body: [String: Any] = [
            "device_id": Store.deviceId,
            "name": deviceName(),
            "push_token": Store.pushToken ?? NSNull(),
            "platform": "ios",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "schema": schemaVersion,
        ]
        switch await request("/api/miniem/register", method: "POST", body: body) {
        case .success:
            Store.registered = fingerprint
            return nil
        case .failure(let failure):
            return failure.message
        }
    }

    /// Fetches this phone's cards and caches them for the widget.
    static func refresh() async -> Result<[Card], Failure> {
        let device = Store.deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch await request("/api/miniem/cards?device_id=\(device)") {
        case .success(let data):
            guard let cards = CardParser.parseList(data) else {
                return .failure(Failure(message: "Home Assistant answered with something unreadable."))
            }
            Store.writeCache(data)
            return .success(cards)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Sends a button press with every input's value; drops the card from the cache when it dismisses.
    static func send(cardId: String, action: Action, values: [String: JSONValue]) async -> String? {
        var body: [String: Any] = [
            "device_id": Store.deviceId,
            "card_id": cardId,
            "values": values.mapValues { $0.any },
            "dismiss": action.dismisses,
        ]
        switch action {
        case .event(let name, let data, _):
            body["type"] = "event"; body["name"] = name; body["data"] = data?.mapValues { $0.any } ?? NSNull()
        case .service(let service, let data, _):
            body["type"] = "service"; body["service"] = service; body["data"] = data?.mapValues { $0.any } ?? NSNull()
        case .dismiss:
            body["type"] = "dismiss"
        case .openURL, .prompt:
            return nil
        }
        switch await request("/api/miniem/action", method: "POST", body: body) {
        case .success:
            if action.dismisses { Store.removeFromCache(cardId: cardId) }
            return nil
        case .failure(let failure):
            return failure.message
        }
    }

    struct EntityState { let name: String; let state: String }

    static func entityState(_ entityId: String) async -> EntityState? {
        guard case .success(let data) = await request("/api/states/\(entityId)"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let attributes = json["attributes"] as? [String: Any] ?? [:]
        let unit = attributes["unit_of_measurement"] as? String ?? ""
        let state = (json["state"] as? String ?? "") + (unit.isEmpty ? "" : " \(unit)")
        return EntityState(name: attributes["friendly_name"] as? String ?? entityId, state: state)
    }

    /// Image bytes: paths starting with `/` are Home Assistant's own and get the token.
    static func imageData(_ source: String) async -> Data? {
        if source.hasPrefix("/") {
            if case .success(let data) = await request(source) { return data }
            return nil
        }
        guard source.hasPrefix("https://"), let url = URL(string: source) else { return nil }
        return try? await session.data(from: url).0
    }

    /// "iPhone (iPhone17,1)". The user-given device name needs a special entitlement since iOS 16.
    private static func deviceName() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : "iPhone (\(machine))"
    }
}
