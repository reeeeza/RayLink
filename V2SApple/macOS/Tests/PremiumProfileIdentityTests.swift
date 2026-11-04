import Foundation

// Only the unrelated public-feed parser is replaced. The persisted data model
// and premium profile replacement logic below are the production source.
enum V2SXray {
    static func makeProfile(from: String) throws -> V2SProfile { throw TestError.unusedParser }
    static func configuration(from: String) throws -> [String: Any] { throw TestError.unusedParser }
}
enum TestError: Error { case unusedParser }

@main struct PremiumProfileIdentityTests {
    static func main() throws {
        let manual = V2SProfile(name: "Manual", protocolName: "trojan", server: "example.invalid", port: 443, shareLink: "test-manual")
        var old = V2SProfile(name: "Premium", protocolName: "trojan", server: "example.invalid", port: 443, shareLink: "test-premium")
        old.isPremium = true
        old.latencyMilliseconds = 125
        var data = V2SData(profiles: [manual, old])
        var refreshed = old
        refreshed.id = UUID()
        refreshed.name = "Updated Premium"
        refreshed.latencyMilliseconds = nil
        data.replacePremiumProfiles(with: [refreshed])
        // Exactly the lookup the packet tunnel uses after a repeated refresh.
        let saved = data.profiles.first { $0.shareLink == refreshed.shareLink }!
        precondition(saved.id == old.id && saved.id != refreshed.id)
        precondition(saved.name == "Updated Premium" && saved.latencyMilliseconds == 125)
        precondition(data.profiles.first { $0.id == saved.id } != nil)
        precondition(data.profiles.first == manual)
        // Persistence must round-trip the ID used for activeProfileID.
        data = try JSONDecoder().decode(V2SData.self, from: JSONEncoder().encode(data))
        precondition(data.profiles.contains { $0.id == saved.id })
        // A rotated credential is a different profile, never an old credential.
        var rotated = refreshed
        rotated.id = UUID()
        rotated.shareLink = "test-rotated"
        data.replacePremiumProfiles(with: [rotated])
        precondition(!data.profiles.contains { $0.id == saved.id })
        precondition(data.profiles.contains { $0.id == rotated.id && $0.isPremium == true && $0.isV2SOperated == true })
        // Revocation removes only Premium entries.
        data.replacePremiumProfiles(with: [])
        precondition(data.profiles == [manual])
        var legacyPublic = manual
        legacyPublic.id = UUID()
        legacyPublic.isCommunity = true
        var allowedPublic = legacyPublic
        allowedPublic.id = UUID()
        allowedPublic.communityCatalogVersion = 3
        var migration = V2SData(profiles: [manual, old, legacyPublic, allowedPublic])
        precondition(migration.removeLegacyCommunityProfiles())
        precondition(migration.profiles == [manual, old, allowedPublic])
        precondition(!migration.removeLegacyCommunityProfiles())
        let now = Date(timeIntervalSince1970: 1_000)
        var lease = V2SPremiumLease()
        precondition(!lease.isActive(at: now))
        let original = lease.beginVerification()
        precondition(lease.accept(revision: original, expiresAt: now.addingTimeInterval(10), now: now))
        precondition(lease.isActive(at: now.addingTimeInterval(9)))
        precondition(!lease.isActive(at: now.addingTimeInterval(10)))
        // A response that arrives after its server-issued expiry cannot grant access.
        let expired = lease.beginVerification()
        precondition(!lease.accept(revision: expired, expiresAt: now, now: now))
        // Refund/expiry invalidation beats an in-flight successful response.
        let pending = lease.beginVerification()
        lease.invalidate()
        precondition(!lease.accept(revision: pending, expiresAt: now.addingTimeInterval(50), now: now))
        precondition(!lease.isActive(at: now))
        // Out-of-order responses cannot overwrite the newest renewal lease.
        let stale = lease.beginVerification()
        let renewal = lease.beginVerification()
        precondition(lease.accept(revision: renewal, expiresAt: now.addingTimeInterval(100), now: now))
        precondition(!lease.accept(revision: stale, expiresAt: now.addingTimeInterval(500), now: now))
        precondition(lease.expiresAt == now.addingTimeInterval(100))
        print("PASS: lease expiry boundary, late response, revocation race, out-of-order renewal")
        print("PASS: refreshed ID, latency/name merge, tunnel lookup, persistence, credential rotation, revocation isolation")
    }
}
