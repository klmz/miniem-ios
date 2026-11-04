import AppIntents
import Foundation
import WidgetKit

// App Intents run by the widget's buttons and toggles, in the widget's own process, without
// opening the app. They live in Shared because the widget extension has to contain them.

extension Action {
    /// The action as card JSON again, to carry it through an intent's string parameter.
    var jsonObject: [String: Any] {
        switch self {
        case .event(let name, let data, let dismiss):
            return ["type": "event", "name": name, "data": data?.mapValues { $0.any } ?? NSNull(), "dismiss": dismiss]
        case .service(let service, let data, let dismiss):
            return ["type": "service", "service": service, "data": data?.mapValues { $0.any } ?? NSNull(), "dismiss": dismiss]
        case .dismiss:
            return ["type": "dismiss"]
        case .openURL(let url):
            return ["type": "open_url", "url": url.absoluteString]
        case .prompt(let title, let key, let numeric, let confirm, let then):
            return ["type": "prompt", "title": title, "key": key, "keyboard": numeric ? "number" : "text",
                    "confirm": confirm, "action": then.jsonObject]
        }
    }

    var jsonString: String {
        (try? JSONSerialization.data(withJSONObject: jsonObject)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func from(jsonString: String) -> Action? {
        guard let data = jsonString.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return CardParser.parseAction(object)
    }
}

/// A button on the widget: sends the action with the card's values, as the app would.
struct CardActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Press a Miniem card button"
    static var isDiscoverable = false

    @Parameter(title: "Card") var cardId: String
    @Parameter(title: "Action") var action: String

    init() {}

    init(cardId: String, action: Action) {
        self.cardId = cardId
        self.action = action.jsonString
    }

    func perform() async throws -> some IntentResult {
        guard let parsed = Action.from(jsonString: action),
              let card = Store.cachedCards().first(where: { $0.id == cardId }) else { return .result() }
        let values = initialValues(card.body).merging(Store.widgetValues(cardId: cardId)) { _, widget in widget }
        _ = await HAClient.send(cardId: cardId, action: parsed, values: values)
        // Pick up whatever Home Assistant changed in answer, then let WidgetKit redraw.
        _ = await HAClient.refresh()
        return .result()
    }
}

/// A switch on the widget. A widget holds no state, so the value is kept in the App Group
/// until a button on the same card sends it.
struct CardToggleIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Flip a Miniem card switch"
    static var isDiscoverable = false

    @Parameter(title: "Card") var cardId: String
    @Parameter(title: "Key") var key: String
    @Parameter(title: "On") var value: Bool

    init() {}

    init(cardId: String, key: String) {
        self.cardId = cardId
        self.key = key
    }

    func perform() async throws -> some IntentResult {
        Store.setWidgetValue(cardId: cardId, key: key, value: .bool(value))
        return .result()
    }
}
