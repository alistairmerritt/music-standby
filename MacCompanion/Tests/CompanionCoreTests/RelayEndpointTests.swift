import CompanionCore
import Foundation
import Testing

@Suite struct RelayEndpointTests {
    @Test func theBuiltInHostIsUsedOverHTTPS() {
        let url = RelayEndpoint.url(override: nil, builtInHost: "relay.example.workers.dev")
        // The Keychain item is keyed by this string, so it must match the
        // hand-set `relayURL` it replaces: no trailing slash.
        #expect(url?.absoluteString == "https://relay.example.workers.dev")
    }

    @Test func aRelayURLInDefaultsWins() {
        let url = RelayEndpoint.url(override: "http://127.0.0.1:8787", builtInHost: "relay.example.workers.dev")
        #expect(url?.absoluteString == "http://127.0.0.1:8787")
    }

    @Test func anUnusableRelayURLFallsBackToTheBuiltInHost() {
        for bad in ["", "   ", "not a url", "ftp://relay.example", "relay.example.workers.dev"] {
            #expect(RelayEndpoint.url(override: bad, builtInHost: "relay.example.workers.dev")?.absoluteString == "https://relay.example.workers.dev", "\(bad)")
        }
    }

    @Test func noRelayWithoutEither() {
        #expect(RelayEndpoint.url(override: nil, builtInHost: nil) == nil)
        #expect(RelayEndpoint.url(override: nil, builtInHost: "") == nil)
        #expect(RelayEndpoint.url(override: nil, builtInHost: "  ") == nil)
    }

    @Test func aBuiltInHostIsOnlyAHost() {
        for bad in ["https://relay.example", "relay.example/v1", "relay.example:8787", "user@relay.example", "$(MSB_RELAY_HOST)"] {
            #expect(RelayEndpoint.url(override: nil, builtInHost: bad) == nil, "\(bad)")
        }
    }
}
