import XCTest
#if canImport(Miniem)
@testable import Miniem
#else
@testable import MiniemShared
#endif

final class CardsTests: XCTestCase {
    private let body = """
    {"cards": [
      {"id": "blinds", "title": "Blinds opened", "updated_at": 200, "priority": 1,
       "body": [
         {"type": "text", "text": "The bedroom blinds just opened.", "style": "caption"},
         {"type": "row", "children": [
           {"type": "button", "label": "Undo", "style": "danger", "action": "undo"},
           {"type": "button", "label": "Fine", "action": {"type": "dismiss"}}
         ]},
         {"type": "hologram", "text": "from the future"}
       ]},
      {"id": "dinner", "updated_at": 300, "expires_at": 1000,
       "body": [
         {"type": "text_field", "key": "note", "placeholder": "What's for dinner?"},
         {"type": "switch", "key": "lights", "label": "Dim the lights", "value": true},
         {"type": "slider", "key": "temp", "min": 15, "max": 25, "step": 0.5, "value": 40},
         {"type": "select", "key": "who", "options": ["Joost", {"value": "m", "label": "Merle"}], "value": "m"},
         {"type": "button", "label": "Off", "action": {"type": "service", "service": "light.turn_off",
           "data": {"entity_id": "light.dining_room"}, "dismiss": false}}
       ]},
      {"id": "empty", "body": []},
      {"title": "no id"}
    ]}
    """.data(using: .utf8)!

    func testCardsWithoutIdOrContentAreDropped() {
        XCTAssertEqual(CardParser.parseList(body)?.map(\.id), ["blinds", "dinner"])
    }

    func testUnknownNodesAreSkipped() {
        let blinds = CardParser.parseList(body)![0]
        XCTAssertEqual(blinds.body.count, 2)
        guard case .row(let children) = blinds.body[1],
              case .button(_, let undo, let style) = children[0],
              case .button(_, let fine, _) = children[1] else { return XCTFail("row of buttons expected") }
        XCTAssertEqual(style, .danger)
        XCTAssertEqual(undo, .event(name: "undo", data: nil, dismiss: true))
        XCTAssertEqual(fine, .dismiss)
    }

    func testInputsAreReadAndClamped() {
        let dinner = CardParser.parseList(body)![1]
        guard case .slider(_, _, _, _, let step, let value) = dinner.body[2] else { return XCTFail() }
        XCTAssertEqual(value, 25)
        XCTAssertEqual(step, 0.5)
        guard case .select(_, _, let options, let selected) = dinner.body[3] else { return XCTFail() }
        XCTAssertEqual(options.map(\.label), ["Joost", "Merle"])
        XCTAssertEqual(selected, "m")
        guard case .button(_, .service(let service, let data, let dismiss), _) = dinner.body[4] else { return XCTFail() }
        XCTAssertEqual(service, "light.turn_off")
        XCTAssertEqual(data?["entity_id"], .string("light.dining_room"))
        XCTAssertFalse(dismiss)
    }

    func testInitialValuesCoverEveryInput() {
        let dinner = CardParser.parseList(body)![1]
        XCTAssertEqual(initialValues(dinner.body), ["note": .string(""), "lights": .bool(true), "temp": .number(25), "who": .string("m")])
    }

    func testExpiryAndOrder() {
        let cards = CardParser.parseList(body)!
        XCTAssertEqual(visibleCards(cards, nowMillis: 999).map(\.id), ["blinds", "dinner"])
        XCTAssertEqual(visibleCards(cards, nowMillis: 1000).map(\.id), ["blinds"])
    }

    func testPrompt() {
        let prompt = CardParser.parseAction(["type": "prompt", "title": "How long?", "key": "minutes", "keyboard": "number",
                                             "action": ["type": "event", "name": "pause", "dismiss": false]])
        XCTAssertEqual(prompt, .prompt(title: "How long?", key: "minutes", numeric: true, confirm: "OK",
                                       then: .event(name: "pause", data: nil, dismiss: false)))
        XCTAssertNil(CardParser.parseAction(["type": "prompt", "key": "k", "action": ["type": "dismiss"]]))
        XCTAssertEqual(promptValue(" 45 ", numeric: true), .number(45))
        XCTAssertEqual(promptValue("1,5", numeric: true), .number(1.5))
        XCTAssertNil(promptValue("soon", numeric: true))
        XCTAssertEqual(promptValue(" soon ", numeric: false), .string("soon"))
    }

    func testOnlyHttpsAndWellFormedServices() {
        XCTAssertNil(CardParser.parseAction(["type": "open_url", "url": "http://x.y"]))
        XCTAssertNil(CardParser.parseAction(["type": "service", "service": "rm -rf"]))
        XCTAssertNotNil(CardParser.parseAction(["type": "open_url", "url": "https://x.y"]))
    }

    func testNestingIsBounded() {
        var node = #"{"type": "text", "text": "deep"}"#
        for _ in 0..<20 { node = #"{"type": "column", "children": [\#(node)]}"# }
        let cards = CardParser.parseList(#"{"cards": [{"id": "deep", "title": "t", "body": [\#(node)]}]}"#.data(using: .utf8)!)!
        XCTAssertTrue(cards[0].body.isEmpty)
    }

    func testValuesEncodeBack() {
        XCTAssertEqual(JSONValue(any: ["a": true, "b": 2, "c": "x"]), .object(["a": .bool(true), "b": .number(2), "c": .string("x")]))
        XCTAssertEqual(JSONValue.number(30).any as? Int64, 30)
    }
}
