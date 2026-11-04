import Foundation
import UserNotifications
import WidgetKit

/// What the panel shows. One instance, shared by the views and the push handler.
@MainActor
final class PanelModel: ObservableObject {
    static let shared = PanelModel()

    @Published private(set) var cards: [Card] = Store.cachedCards()
    @Published private(set) var refreshing = false
    @Published private(set) var problem: String?
    @Published private(set) var configured = Store.configured
    @Published private(set) var url: String? = Store.url
    @Published private(set) var sending: Set<String> = []
    /// Set by a miniem://card/<id> link (from the widget) so the panel can scroll to it.
    @Published var highlighted: String?

    var pushAvailable: Bool { AppDelegate.pushAvailable }
    var pushRegistered: Bool { Store.pushToken != nil && Store.registered != nil }

    func resume() async {
        guard Store.configured else { return }
        _ = await HAClient.register()
        await refresh()
        markSeen()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard Store.configured else { return false }
        refreshing = true
        defer { refreshing = false }
        switch await HAClient.refresh() {
        case .success(let fresh):
            cards = fresh
            problem = nil
            WidgetCenter.shared.reloadAllTimelines()
            return true
        case .failure(let failure):
            problem = failure.message
            return false
        }
    }

    func send(card: Card, action: Action, values: [String: JSONValue]) async {
        sending.insert(card.id)
        let failure = await HAClient.send(cardId: card.id, action: action, values: values)
        sending.remove(card.id)
        problem = failure
        if failure == nil && action.dismisses {
            cards.removeAll { $0.id == card.id }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func connect(url raw: String, token: String) async {
        guard let url = Store.normalize(raw) else {
            problem = "That is not an https address."
            return
        }
        Store.url = url
        Store.registered = nil
        if !token.isEmpty && !Store.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines)) {
            problem = "Could not store the token."
            return
        }
        configured = Store.configured
        self.url = url
        await requestNotifications()
        problem = await HAClient.register(force: true)
        if problem == nil { await refresh() }
    }

    func disconnect() {
        Store.clear()
        cards = []
        configured = false
        url = nil
        problem = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    func markSeen() {
        if let newest = cards.map(\.updatedAt).max(), newest > Store.lastSeenAt { Store.lastSeenAt = newest }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func open(_ url: URL) {
        guard url.scheme == "miniem" else { return }
        if url.host == "card" { highlighted = url.lastPathComponent }
        Task { await refresh() }
    }

    /// Only needed for focus cards, which arrive as notifications; asked once, on connect.
    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
