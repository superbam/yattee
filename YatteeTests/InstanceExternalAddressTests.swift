//
//  InstanceExternalAddressTests.swift
//  YatteeTests
//
//  The external address is stored on the instance and syncs through iCloud as part of the
//  encoded instance list, so it must round-trip and must not break data saved before it existed.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Instance external address")
struct InstanceExternalAddressTests {
    private let home = URL(string: "http://192.168.1.6:3000")!
    private let external = URL(string: "https://invidious.example.com")!

    @Test("External address survives the encode/decode used for iCloud sync")
    func roundTrip() throws {
        let instance = Instance(type: .invidious, url: home, externalURL: external)
        let decoded = try JSONDecoder().decode(Instance.self, from: JSONEncoder().encode(instance))
        #expect(decoded.url == home)
        #expect(decoded.externalURL == external)
        #expect(decoded.id == instance.id)
    }

    @Test("Instances saved before the external address existed still decode")
    func decodesLegacyData() throws {
        let legacy = Instance(type: .invidious, url: home)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "externalURL")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Instance.self, from: data)
        #expect(decoded.externalURL == nil)
        #expect(decoded.url == home)
    }

    @Test("Switching address keeps the instance identity")
    func withURLKeepsIdentity() {
        let instance = Instance(type: .invidious, url: home, externalURL: external)
        let away = instance.withURL(external)
        #expect(away.id == instance.id)
        #expect(away.isUsingExternalAddress)
        #expect(!instance.isUsingExternalAddress)
    }

    @Test("Video is relayed through the server only on the external address")
    func proxyingFollowsAddress() {
        let instance = Instance(type: .invidious, url: home, proxiesVideos: false, externalURL: external)
        #expect(!instance.effectiveProxiesVideos)
        #expect(instance.withURL(external).effectiveProxiesVideos)
    }

    @Test("An instance without an external address never reports using one")
    func noExternalAddress() {
        let instance = Instance(type: .invidious, url: home)
        #expect(!instance.isUsingExternalAddress)
        #expect(!instance.effectiveProxiesVideos)
    }
}
