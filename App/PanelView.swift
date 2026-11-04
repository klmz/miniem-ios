import SwiftUI

/// The panel: whatever Home Assistant put here for this phone, then the connection.
/// Quiet on purpose, like the Android launcher: one flat background, faint type.
struct PanelView: View {
    @EnvironmentObject private var model: PanelModel
    @State private var now = nowMillis()
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Home").font(.title2).foregroundStyle(.primary.opacity(0.85))
                        Spacer()
                        if model.configured {
                            Button(model.refreshing ? "updating…" : "refresh") { Task { await model.refresh() } }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let problem = model.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red.opacity(0.8))
                    }

                    let cards = visibleCards(model.cards, nowMillis: now)
                    if !model.configured {
                        Text("Connect Home Assistant below. Automations can then put questions, buttons and fields here — and on your home screen, with the Miniem widget.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if cards.isEmpty {
                        Text(model.refreshing ? "Asking Home Assistant…" : "Nothing to ask you. The house is behaving.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(cards) { card in
                            CardView(card: card, sending: model.sending.contains(card.id)) { action, values in
                                Task { await model.send(card: card, action: action, values: values) }
                            }
                            // A replaced card starts from its new values.
                            .id("\(card.id)-\(card.updatedAt)")
                        }
                    }

                    ConnectionSection()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .refreshable { await model.refresh() }
            .onChange(of: model.highlighted) { _, id in
                guard let id, let card = model.cards.first(where: { $0.id == id }) else { return }
                withAnimation { proxy.scrollTo("\(card.id)-\(card.updatedAt)", anchor: .top) }
                model.highlighted = nil
            }
        }
        .onReceive(ticker) { _ in now = nowMillis() }
        .onAppear { model.markSeen() }
    }
}

private struct ConnectionSection: View {
    @EnvironmentObject private var model: PanelModel
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTION").font(.caption2).tracking(1.5).foregroundStyle(.secondary)
            if model.configured {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.url?.replacingOccurrences(of: "https://", with: "") ?? "").font(.body)
                        Text("Long-lived token stored · " + pushLine).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { model.disconnect() }.font(.subheadline)
                }
            } else {
                Text("Your Home Assistant address, and a long-lived access token from your profile's Security tab. The Miniem integration has to be installed there.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("homeassistant.example.ts.net", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Long-lived access token", text: $token).textFieldStyle(.roundedBorder)
                Button("Connect") {
                    Task {
                        await model.connect(url: url, token: token)
                        token = ""
                    }
                }
                .disabled(url.isEmpty || token.isEmpty)
            }
        }
        .padding(.top, 28)
    }

    private var pushLine: String {
        if !model.pushAvailable { return "no push in this build" }
        return model.pushRegistered ? "push on" : "push not registered yet"
    }
}
