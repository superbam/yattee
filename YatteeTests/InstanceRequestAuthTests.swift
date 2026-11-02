//
//  InstanceRequestAuthTests.swift
//  YatteeTests
//
//  The reverse-proxy credentials must only ever be attached to the host they belong to.
//

import Foundation
import Testing
@testable import Yattee

@Suite("InstanceRequestAuth", .serialized)
struct InstanceRequestAuthTests {
    private let auth = InstanceRequestAuth.shared

    @Test("Adds the header for a configured host only")
    func hostScoped() {
        auth.update(["invidious.example.com": "Basic abc"])
        defer { auth.update([:]) }

        let own = auth.request(for: URL(string: "https://invidious.example.com/vi/x/mqdefault.jpg")!)
        #expect(own.value(forHTTPHeaderField: "Authorization") == "Basic abc")

        let other = auth.request(for: URL(string: "https://i.ytimg.com/vi/x/mqdefault.jpg")!)
        #expect(other.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Host matching ignores case")
    func caseInsensitive() {
        auth.update(["invidious.example.com": "Basic abc"])
        defer { auth.update([:]) }
        let request = auth.request(for: URL(string: "https://Invidious.Example.com/x")!)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic abc")
    }

    @Test("Never overrides a header the caller already set")
    func keepsExistingHeader() {
        auth.update(["invidious.example.com": "Basic abc"])
        defer { auth.update([:]) }
        var request = URLRequest(url: URL(string: "https://invidious.example.com/x")!)
        request.setValue("Bearer other", forHTTPHeaderField: "Authorization")
        #expect(auth.authorized(request).value(forHTTPHeaderField: "Authorization") == "Bearer other")
    }

    @Test("Clearing the table removes access")
    func cleared() {
        auth.update(["invidious.example.com": "Basic abc"])
        auth.update([:])
        #expect(auth.request(for: URL(string: "https://invidious.example.com/x")!).value(forHTTPHeaderField: "Authorization") == nil)
    }
}
