import Foundation
import Testing
@testable import CcinnMysqlKit

@Suite("Window requests")
struct WindowRequestTests {
    @Test func everyRequestOpensItsOwnWindow() {
        let profile = UUID()
        // SwiftUI brings an existing window to the front when the value is equal, so two requests for the same
        // connection must differ.
        #expect(WindowRequest(profileID: profile) != WindowRequest(profileID: profile))
        #expect(WindowRequest(profileID: profile).profileID == profile)
    }

    @Test func roundTripsThroughCodable() throws {
        let request = WindowRequest(profileID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(decoded.nonce == request.nonce)
    }

    @Test func decodesWithoutTheNonce() throws {
        let profile = UUID()
        let json = Data(#"{"profileID":"\#(profile.uuidString)"}"#.utf8)
        let first = try JSONDecoder().decode(WindowRequest.self, from: json)
        let second = try JSONDecoder().decode(WindowRequest.self, from: json)
        #expect(first.profileID == profile)
        #expect(first != second, "each decoded request still opens its own window")
    }

    @Test func rejectsARequestWithoutAProfile() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"nonce":"\#(UUID().uuidString)"}"#.utf8))
        }
    }
}

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(request) == "secret")
        #expect(handoff.take(request) == nil, "a second window must not reuse the connection")
        #expect(handoff.pendingCount == 0)
    }

    @Test func restoredRequestsCarryNothing() throws {
        // A request decoded after a relaunch (window restoration) was not created by this process.
        let handoff = WindowHandoff<String>()
        let issued = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.take(WindowRequest(profileID: issued.profileID)) == nil)
        let restored = try JSONDecoder().decode(WindowRequest.self,
                                                from: Data(#"{"profileID":"\#(issued.profileID.uuidString)"}"#.utf8))
        #expect(handoff.take(restored) == nil)
        #expect(handoff.pendingCount == 1, "unknown requests leave pending handoffs alone")
    }

    @Test func aRestoredRequestTakesThePathOfNoRequest() throws {
        // The window then shows the connection screen (and may consume the launch arguments), exactly like
        // File ▸ New Window: nothing about the restored request connects it.
        let handoff = WindowHandoff<String>()
        let issued = handoff.request(profileID: UUID(), payload: "secret")
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(WindowRequest(profileID: issued.profileID)))
        #expect(handoff.take(nil) == nil)
        #expect(handoff.take(restored) == handoff.take(nil))
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(issued) == "secret", "falling through leaves the windows this process opens alone")
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let first = handoff.request(profileID: profile, payload: "a")
        let second = handoff.request(profileID: profile, payload: "b")
        #expect(first != second)
        #expect(first.profileID == profile && second.profileID == profile)
        #expect(handoff.take(second) == "b")
        #expect(handoff.take(first) == "a")
        #expect(handoff.pendingCount == 0)
    }

    @Test func handoffsAreNotShared() {
        let one = WindowHandoff<String>()
        let other = WindowHandoff<String>()
        let request = one.request(profileID: UUID(), payload: "secret")
        #expect(other.take(request) == nil)
        #expect(one.take(request) == "secret")
    }
}
