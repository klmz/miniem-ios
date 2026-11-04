import Foundation

// The server-driven card format, as described in miniem-android's docs/home-assistant.md.
// This parser mirrors the Android one (ha/Cards.kt): anything it does not recognise is
// dropped rather than failing the card, so Home Assistant can get ahead of an older build.

struct Card: Identifiable, Equatable {
    let id: String
    let title: String?
    let subtitle: String?
    let body: [Node]
    /// Epoch millis of the last change on the server.
    let updatedAt: Int64
    let expiresAt: Int64?
    let priority: Int

    func expired(nowMillis: Int64) -> Bool {
        if let expiresAt { return nowMillis >= expiresAt }
        return false
    }
}

struct Option: Equatable, Hashable {
    let value: String
    let label: String
}

enum TextStyle: Equatable { case title, body, caption, mono }
enum CardButtonStyle: Equatable { case primary, secondary, danger }

indirect enum Node: Equatable {
    case text(String, TextStyle)
    case button(label: String, action: Action, style: CardButtonStyle)
    case textField(key: String, label: String?, placeholder: String?, value: String, multiline: Bool, numeric: Bool)
    case toggle(key: String, label: String, value: Bool)
    case slider(key: String, label: String?, min: Double, max: Double, step: Double, value: Double)
    case select(key: String, label: String?, options: [Option], value: String?)
    case entity(entityId: String, label: String?)
    case image(url: String, aspectRatio: Double?)
    case row([Node])
    case column([Node])
    case divider
    case spacer(Int)
}

/// JSON values that travel back to Home Assistant: inputs' values and an action's own data.
enum JSONValue: Equatable, Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(any: Any?) {
        if let any, isJSONBool(any) {
            self = .bool((any as? Bool) ?? (any as? NSNumber)?.boolValue ?? false)
            return
        }
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int64(value) as Any : value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.any }
        case .array(let value): return value.map { $0.any }
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

indirect enum Action: Equatable, Hashable {
    case event(name: String, data: [String: JSONValue]?, dismiss: Bool)
    case service(service: String, data: [String: JSONValue]?, dismiss: Bool)
    case dismiss
    case openURL(URL)
    case prompt(title: String, key: String, numeric: Bool, confirm: String, then: Action)

    /// Whether pressing it takes the card away (on success).
    var dismisses: Bool {
        switch self {
        case .event(_, _, let dismiss), .service(_, _, let dismiss): return dismiss
        case .dismiss: return true
        case .openURL, .prompt: return false
        }
    }
}

enum CardParser {
    private static let maxDepth = 6
    private static let identifier = try! NSRegularExpression(pattern: "^[a-z0-9_]+\\.[a-z0-9_]+$")

    /// The cards in a `{"cards": [...]}` body; nil when the body is not that at all.
    static func parseList(_ data: Data) -> [Card]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["cards"] as? [Any] else { return nil }
        return array.compactMap { ($0 as? [String: Any]).flatMap(parseCard) }
    }

    static func parseCard(_ json: [String: Any]) -> Card? {
        guard let id = string(json, "id") else { return nil }
        let body = nodes(json["body"], depth: 0)
        let title = string(json, "title")
        if body.isEmpty && title == nil { return nil }
        let expires = int64(json["expires_at"])
        return Card(
            id: id,
            title: title,
            subtitle: string(json, "subtitle"),
            body: body,
            updatedAt: int64(json["updated_at"]) ?? 0,
            expiresAt: (expires ?? 0) > 0 ? expires : nil,
            priority: Int(int64(json["priority"]) ?? 0)
        )
    }

    private static func nodes(_ value: Any?, depth: Int) -> [Node] {
        guard depth <= maxDepth, let array = value as? [Any] else { return [] }
        return array.compactMap { ($0 as? [String: Any]).flatMap { node($0, depth: depth) } }
    }

    private static func node(_ json: [String: Any], depth: Int) -> Node? {
        switch json["type"] as? String {
        case "text":
            return string(json, "text").map { .text($0, textStyle(json["style"] as? String)) }
        case "button":
            guard let label = string(json, "label"), let action = parseAction(json["action"]) else { return nil }
            return .button(label: label, action: action, style: buttonStyle(json["style"] as? String))
        case "text_field":
            guard let key = string(json, "key") else { return nil }
            return .textField(key: key, label: string(json, "label"), placeholder: string(json, "placeholder"),
                              value: json["value"] as? String ?? "", multiline: json["multiline"] as? Bool ?? false,
                              numeric: json["keyboard"] as? String == "number")
        case "switch":
            guard let key = string(json, "key"), let label = string(json, "label") else { return nil }
            return .toggle(key: key, label: label, value: json["value"] as? Bool ?? false)
        case "slider":
            guard let key = string(json, "key") else { return nil }
            let min = double(json["min"]) ?? 0
            var max = double(json["max"]) ?? 100
            if max <= min { max = min + 1 }
            let step = Swift.max(double(json["step"]) ?? 0, 0)
            let value = Swift.min(Swift.max(double(json["value"]) ?? min, min), max)
            return .slider(key: key, label: string(json, "label"), min: min, max: max, step: step, value: value)
        case "select":
            guard let key = string(json, "key") else { return nil }
            let options = (json["options"] as? [Any] ?? []).compactMap { item -> Option? in
                if let text = item as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return Option(value: text, label: text) }
                if let object = item as? [String: Any], let value = string(object, "value") { return Option(value: value, label: string(object, "label") ?? value) }
                return nil
            }
            guard !options.isEmpty else { return nil }
            let value = string(json, "value").flatMap { value in options.contains { $0.value == value } ? value : nil }
            return .select(key: key, label: string(json, "label"), options: options, value: value)
        case "entity":
            guard let id = string(json, "entity_id"), matches(id) else { return nil }
            return .entity(entityId: id, label: string(json, "label"))
        case "image":
            guard let url = string(json, "url") else { return nil }
            let ratio = double(json["aspect_ratio"])
            return .image(url: url, aspectRatio: (ratio ?? 0) > 0 ? ratio : nil)
        case "row":
            let children = nodes(json["children"], depth: depth + 1)
            return children.isEmpty ? nil : .row(children)
        case "column":
            let children = nodes(json["children"], depth: depth + 1)
            return children.isEmpty ? nil : .column(children)
        case "divider":
            return .divider
        case "spacer":
            return .spacer(Swift.min(Swift.max(Int(int64(json["size"]) ?? 12), 0), 96))
        default:
            return nil
        }
    }

    /// An action object, or a bare string as shorthand for an event of that name.
    static func parseAction(_ value: Any?) -> Action? {
        if let name = value as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .event(name: trimmed, data: nil, dismiss: true)
        }
        guard let json = value as? [String: Any] else { return nil }
        let data = (json["data"] as? [String: Any])?.mapValues { JSONValue(any: $0) }
        let dismiss = json["dismiss"] as? Bool ?? true
        switch json["type"] as? String ?? "event" {
        case "event":
            return string(json, "name").map { .event(name: $0, data: data, dismiss: dismiss) }
        case "service":
            guard let service = string(json, "service"), matches(service) else { return nil }
            return .service(service: service, data: data, dismiss: dismiss)
        case "dismiss":
            return .dismiss
        case "open_url":
            guard let text = string(json, "url"), text.hasPrefix("https://"), let url = URL(string: text) else { return nil }
            return .openURL(url)
        case "prompt":
            guard let key = string(json, "key"), let then = parseAction(json["action"]) else { return nil }
            switch then {
            case .event, .service: break
            default: return nil
            }
            return .prompt(title: string(json, "title") ?? "Enter a value", key: key,
                           numeric: json["keyboard"] as? String == "number",
                           confirm: string(json, "confirm") ?? "OK", then: then)
        default:
            return nil
        }
    }

    private static func textStyle(_ name: String?) -> TextStyle {
        switch name {
        case "title": return .title
        case "caption": return .caption
        case "mono": return .mono
        default: return .body
        }
    }

    private static func buttonStyle(_ name: String?) -> CardButtonStyle {
        switch name {
        case "primary": return .primary
        case "danger": return .danger
        default: return .secondary
        }
    }

    private static func string(_ json: [String: Any], _ key: String) -> String? {
        guard let value = json[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isJSONBool(value as Any) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func int64(_ value: Any?) -> Int64? { double(value).map { Int64($0) } }

    private static func matches(_ text: String) -> Bool {
        identifier.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Which cards are on show, in the order the panel and the widget draw them.
func visibleCards(_ cards: [Card], nowMillis: Int64) -> [Card] {
    cards.filter { !$0.expired(nowMillis: nowMillis) }
        .sorted { ($0.priority, $0.updatedAt) > ($1.priority, $1.updatedAt) }
}

/// The initial values of every input, keyed as Home Assistant gets them back.
func initialValues(_ nodes: [Node]) -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    func walk(_ list: [Node]) {
        for node in list {
            switch node {
            case .textField(let key, _, _, let value, _, _): values[key] = .string(value)
            case .toggle(let key, _, let value): values[key] = .bool(value)
            case .slider(let key, _, _, _, _, let value): values[key] = .number(value)
            case .select(let key, _, _, let value): if let value { values[key] = .string(value) }
            case .row(let children), .column(let children): walk(children)
            default: break
            }
        }
    }
    walk(nodes)
    return values
}

/// What a prompt's input goes back as; nil while it is not something to send.
func promptValue(_ input: String, numeric: Bool) -> JSONValue? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if !numeric { return .string(text) }
    guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
    return .number(number)
}

/// JSONSerialization hands Bools over as NSNumbers on Apple platforms, where only the
/// CFBoolean type id tells them apart from 0 and 1.
func isJSONBool(_ value: Any) -> Bool {
    #if canImport(Darwin)
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
    #else
    // On Linux an NSNumber holding 0 or 1 passes `is Bool`; only the exact type is reliable.
    return type(of: value) == Bool.self
    #endif
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
