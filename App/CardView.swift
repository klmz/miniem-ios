import SwiftUI

/// Draws one card from its description. Inputs keep their values here and travel along
/// with every button press on the card.
struct CardView: View {
    let card: Card
    let sending: Bool
    let onAction: (Action, [String: JSONValue]) -> Void

    @State private var values: [String: JSONValue]
    @State private var prompt: PromptState?

    init(card: Card, sending: Bool, onAction: @escaping (Action, [String: JSONValue]) -> Void) {
        self.card = card
        self.sending = sending
        self.onAction = onAction
        _values = State(initialValue: initialValues(card.body))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.title != nil || card.subtitle != nil {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = card.title { Text(title).font(.headline) }
                        if let subtitle = card.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(sending ? "…" : "×") { act(.dismiss) }
                        .font(.title3).foregroundStyle(.secondary).disabled(sending)
                }
            }
            ForEach(Array(card.body.enumerated()), id: \.offset) { _, node in
                NodeView(node: node, values: $values, enabled: !sending, act: act)
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.14)))
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            PromptFields(prompt: $prompt) { key, value, then in
                var sent = values
                sent[key] = value
                onAction(then, sent)
            }
        }
    }

    private func act(_ action: Action) {
        switch action {
        case .openURL(let url):
            UIApplication.shared.open(url)
        case .prompt(let title, let key, let numeric, let confirm, let then):
            prompt = PromptState(title: title, key: key, numeric: numeric, confirm: confirm, then: then)
        default:
            onAction(action, values)
        }
    }
}

struct PromptState {
    let title: String
    let key: String
    let numeric: Bool
    let confirm: String
    let then: Action
    var input = ""
}

private struct PromptFields: View {
    @Binding var prompt: PromptState?
    let onConfirm: (String, JSONValue, Action) -> Void

    var body: some View {
        if let current = prompt {
            TextField("", text: Binding(get: { prompt?.input ?? "" }, set: { prompt?.input = $0 }))
                .keyboardType(current.numeric ? .decimalPad : .default)
            Button(current.confirm) {
                if let value = promptValue(current.input, numeric: current.numeric) {
                    onConfirm(current.key, value, current.then)
                }
                prompt = nil
            }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }
}

struct NodeView: View {
    let node: Node
    @Binding var values: [String: JSONValue]
    let enabled: Bool
    let act: (Action) -> Void

    var body: some View {
        switch node {
        case .text(let text, let style):
            Text(text)
                .font(style == .title ? .headline : style == .caption ? .caption : style == .mono ? .system(.footnote, design: .monospaced) : .body)
                .foregroundStyle(style == .caption ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .button(let label, let action, let style):
            Button(action: { act(action) }) {
                Text(label).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(style == .danger ? Color.red : style == .primary ? Color.accentColor : Color.gray)
            .modifier(Prominent(on: style == .primary))
            .disabled(!enabled)

        case .textField(let key, let label, let placeholder, _, let multiline, let numeric):
            VStack(alignment: .leading, spacing: 4) {
                if let label { Text(label).font(.footnote).foregroundStyle(.secondary) }
                TextField(placeholder ?? "", text: stringBinding(key), axis: multiline ? .vertical : .horizontal)
                    .lineLimit(multiline ? 3...6 : 1...1)
                    .keyboardType(numeric ? .decimalPad : .default)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!enabled)
            }

        case .toggle(let key, let label, _):
            Toggle(label, isOn: Binding(
                get: { if case .bool(let value) = values[key] { return value }; return false },
                set: { values[key] = .bool($0) }
            ))
            .disabled(!enabled)

        case .slider(let key, let label, let min, let max, let step, _):
            let value = Binding<Double>(
                get: { if case .number(let value) = values[key] { return value }; return min },
                set: { values[key] = .number($0) }
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label ?? "").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text(step == 0 || step.truncatingRemainder(dividingBy: 1) == 0
                         ? String(Int(value.wrappedValue.rounded())) : String(format: "%.1f", value.wrappedValue))
                        .font(.footnote)
                }
                if step > 0 {
                    Slider(value: value, in: min...max, step: step).disabled(!enabled)
                } else {
                    Slider(value: value, in: min...max).disabled(!enabled)
                }
            }

        case .select(let key, let label, let options, _):
            VStack(alignment: .leading, spacing: 4) {
                if let label { Text(label).font(.footnote).foregroundStyle(.secondary) }
                Picker(label ?? "", selection: stringBinding(key)) {
                    ForEach(options, id: \.self) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
            }

        case .entity(let entityId, let label):
            EntityRow(entityId: entityId, label: label)

        case .image(let url, let ratio):
            RemoteImage(source: url, aspectRatio: ratio)

        case .row(let children):
            HStack(spacing: 10) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    NodeView(node: child, values: $values, enabled: enabled, act: act)
                }
            }

        case .column(let children):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    NodeView(node: child, values: $values, enabled: enabled, act: act)
                }
            }

        case .divider:
            Divider()

        case .spacer(let size):
            Color.clear.frame(height: CGFloat(size))
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { if case .string(let value) = values[key] { return value }; return "" },
            set: { values[key] = .string($0) }
        )
    }
}

private struct Prominent: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content }
    }
}

/// Live enough for a panel someone is looking at: re-read every 10 seconds while on screen.
private struct EntityRow: View {
    let entityId: String
    let label: String?
    @State private var entity: HAClient.EntityState?

    var body: some View {
        HStack {
            Text(label ?? entity?.name ?? entityId).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(entity?.state ?? "…")
        }
        .task(id: entityId) {
            while !Task.isCancelled {
                if let fresh = await HAClient.entityState(entityId) { entity = fresh }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct RemoteImage: View {
    let source: String
    let aspectRatio: Double?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(failed ? "image unavailable" : "…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(aspectRatio.map { CGFloat($0) } ?? (image.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 9), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: source) {
            if let data = await HAClient.imageData(source), let loaded = UIImage(data: data) { image = loaded } else { failed = true }
        }
    }
}
