import XCTest
@testable import SmartChatApp

final class SessionKeyTests: XCTestCase {

    func testParse_fullKey_extractsAllFourParts() {
        let k = SessionKey.parse("agent:myagent:mychannel:mylabel:abcdef12-3456-7890")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertEqual(k.channel, "mychannel")
        XCTAssertEqual(k.label, "mylabel")
        XCTAssertEqual(k.uuid, "abcdef12-3456-7890")
        XCTAssertEqual(k.raw, "agent:myagent:mychannel:mylabel:abcdef12-3456-7890")
    }

    func testParse_threePartKey_labelAndUuidCollide_returnsLabelAsUuid() {
        // Existing behavior: when 4th segment is also the label, the
        // uuid fallback returns it. Document the collision.
        let k = SessionKey.parse("agent:myagent:mychannel:onlylabel")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertEqual(k.channel, "mychannel")
        XCTAssertEqual(k.label, "onlylabel")
        XCTAssertEqual(k.uuid, "onlylabel")
    }

    func testParse_twoPartKey_missingChannelAndLabel_areNil() {
        let k = SessionKey.parse("agent:myagent")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertNil(k.channel)
        XCTAssertNil(k.label)
        // uuid falls back to the last 8 chars of the raw key (preserves
        // the existing behavior of NativeChatViewModel.extractSessionUuid).
        XCTAssertEqual(k.uuid, String("agent:myagent".suffix(8)))
    }

    func testParse_emptySegments_areTreatedAsNil() {
        let k = SessionKey.parse("agent:myagent::  :")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertNil(k.channel)
        XCTAssertNil(k.label)
        XCTAssertNil(k.uuid)
    }

    func testMakeNew_producesAgentPrefixAndLowercaseUuid() {
        let s = SessionKey.makeNew(agentId: "MyAgent", clientLabel: "smartchatapp")
        let k = SessionKey.parse(s)
        XCTAssertEqual(k.agentId, "MyAgent")
        // makeNew format is "agent:<agentId>:<clientLabel>:<uuid>" — 4 segments,
        // so the clientLabel lands in the channel slot (segment 2) just like the
        // production SessionPickerView.extractChannel reads it.
        XCTAssertEqual(k.channel, "smartchatapp")
        XCTAssertNotNil(k.uuid)
        XCTAssertEqual(k.uuid, k.uuid?.lowercased()) // already lowercased
        XCTAssertTrue(s.hasPrefix("agent:MyAgent:smartchatapp:"))
    }
}
