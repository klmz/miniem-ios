import AppIntents
import SwiftUI
import WidgetKit

@main
struct MiniemWidgetBundle: WidgetBundle {
    var body: some Widget { MiniemWidget() }
}

struct MiniemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MiniemCard", provider: CardProvider()) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Home Assistant card")
        .description("The card Home Assistant most wants you to see, with its buttons.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CardEntry: TimelineEntry {
    let date: Date
    let configured: Bool
    let cards: [Card]
    /// States for the top card's entity rows, read when the timeline was built.
    let entities: [String: HAClient.EntityState]
}

struct CardProvider: TimelineProvider {
    func placeholder(in context: Context) -> CardEntry {
        CardEntry(date: .now, configured: true, cards: [Self.sample], entities: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (CardEntry) -> Void) {
        let cards = Store.cachedCards()
        completion(CardEntry(date: .now, configured: Store.configured, cards: cards.isEmpty && context.isPreview ? [Self.sample] : cards, entities: [:]))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardEntry>) -> Void) {
        Task {
            var cards = Store.cachedCards()
            if Store.configured, case .success(let fresh) = await HAClient.refresh() { cards = fresh }
            let now = nowMillis()
            let visible = visibleCards(cards, nowMillis: now)

            var entities: [String: HAClient.EntityState] = [:]
            for id in entityIds(in: visible.first?.body ?? []) {
                if let state = await HAClient.entityState(id) { entities[id] = state }
            }

            // Redraw when the next card expires, and otherwise every 15 minutes; pushes
            // reload the timeline sooner whenever a card changes.
            let nextExpiry = visible.compactMap(\.expiresAt).filter { $0 > now }.min()
                .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            let next = min(nextExpiry ?? .distantFuture, Date.now.addingTimeInterval(15 * 60))
            let entry = CardEntry(date: .now, configured: Store.configured, cards: cards, entities: entities)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func entityIds(in nodes: [Node]) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .entity(let id, _): return [id]
            case .row(let children), .column(let children): return entityIds(in: children)
            default: return []
            }
        }
    }

    static let sample = Card(
        id: "sample", title: "Lights off for the TV", subtitle: "21:04",
        body: [
            .button(label: "Undo", action: .dismiss, style: .danger),
            .row([.button(label: "30 min", action: .dismiss, style: .secondary),
                  .button(label: "1 hour", action: .dismiss, style: .secondary)]),
        ],
        updatedAt: 0, expiresAt: nil, priority: 0
    )
}

struct CardWidgetView: View {
    let entry: CardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let cards = visibleCards(entry.cards, nowMillis: Int64(entry.date.timeIntervalSince1970 * 1000))
        if !entry.configured {
            Text("Open Miniem to connect Home Assistant.").font(.footnote).foregroundStyle(.secondary)
        } else if let card = cards.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title ?? "Home Assistant").font(.headline).lineLimit(1)
                    Spacer()
                    if cards.count > 1 { Text("+\(cards.count - 1)").font(.caption).foregroundStyle(.secondary) }
                    if let subtitle = card.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                WidgetNodes(card: card, nodes: card.body, entities: entry.entities, limit: family == .systemLarge ? 12 : 4)
                Spacer(minLength: 0)
            }
            .widgetURL(URL(string: "miniem://card/\(card.id)"))
        } else {
            VStack(alignment: .leading) {
                Text("Home").font(.headline)
                Text("Nothing to ask you.").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The widget-safe subset of the card vocabulary. What a widget cannot hold — text fields,
/// sliders, selects, prompts, images — collapses into one "Open" link to the card in the app.
private struct WidgetNodes: View {
    let card: Card
    let nodes: [Node]
    let entities: [String: HAClient.EntityState]
    let limit: Int

    var body: some View {
        let shown = Array(nodes.prefix(limit))
        let needsApp = nodes.count > limit || nodes.contains(where: Self.needsApp)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, node in
                WidgetNode(card: card, node: node, entities: entities)
            }
            if needsApp, let url = URL(string: "miniem://card/\(card.id)") {
                Link(destination: url) {
                    Text("Open to answer →").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func needsApp(_ node: Node) -> Bool {
        switch node {
        case .textField, .slider, .select, .image: return true
        case .button(_, .prompt, _): return true
        case .row(let children), .column(let children): return children.contains(where: needsApp)
        default: return false
        }
    }
}

private struct WidgetNode: View {
    let card: Card
    let node: Node
    let entities: [String: HAClient.EntityState]

    var body: some View {
        switch node {
        case .text(let text, let style):
            Text(text).font(style == .caption ? .caption : .footnote)
                .foregroundStyle(style == .caption ? .secondary : .primary).lineLimit(2)
        case .button(let label, let action, let style):
            WidgetButton(cardId: card.id, label: label, action: action, style: style)
        case .toggle(let key, let label, let initial):
            let stored = Store.widgetValues(cardId: card.id)[key]
            let isOn: Bool = { if case .bool(let value) = stored { return value }; return initial }()
            Toggle(isOn: isOn, intent: CardToggleIntent(cardId: card.id, key: key)) {
                Text(label).font(.footnote)
            }
        case .entity(let id, let label):
            HStack {
                Text(label ?? entities[id]?.name ?? id).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(entities[id]?.state ?? "…").font(.footnote)
            }
        case .row(let children):
            HStack(spacing: 6) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    WidgetNode(card: card, node: child, entities: entities)
                }
            }
        case .column(let children):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    WidgetNode(card: card, node: child, entities: entities)
                }
            }
        case .divider:
            Divider()
        case .spacer(let size):
            Color.clear.frame(height: CGFloat(min(size, 12)))
        case .textField, .slider, .select, .image:
            EmptyView()
        }
    }
}

private struct WidgetButton: View {
    let cardId: String
    let label: String
    let action: Action
    let style: CardButtonStyle

    var body: some View {
        switch action {
        case .openURL(let url):
            Link(destination: url) { content }
        case .prompt:
            EmptyView()
        default:
            Button(intent: CardActionIntent(cardId: cardId, action: action)) { content }
                .buttonStyle(.bordered)
                .tint(style == .danger ? Color.red : style == .primary ? Color.accentColor : Color.gray)
        }
    }

    private var content: some View {
        Text(label).font(.caption).lineLimit(1).frame(maxWidth: .infinity)
    }
}
