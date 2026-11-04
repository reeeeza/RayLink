import Foundation
import StoreKit

enum RecoveryTestError: Error { case unavailable }

@main struct PremiumRecoveryTests {
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        func candidate(_ id: UInt64, _ seconds: Double, _ value: String) -> V2SPremiumCandidate<String> {
            V2SPremiumCandidate(id: id, expiresAt: now.addingTimeInterval(seconds), value: value)
        }
        var delivered: [String] = []
        // External redemption missed by an empty currentEntitlements snapshot
        // is recovered from unfinished, without a second code redemption.
        let recovered = try await V2SPremiumRecovery.deliverFirst([candidate(1, 60, "unfinished")], now: now) {
            delivered.append($0)
        }
        precondition(recovered && delivered == ["unfinished"])

        // Repeated unfinished/current entries and an expired period cannot
        // provision twice; a later active plan is tried first.
        delivered = []
        let latest = try await V2SPremiumRecovery.deliverFirst([
            candidate(1, 60, "monthly"), candidate(2, 300, "yearly"),
            candidate(2, 300, "yearly"), candidate(3, 0, "expired")
        ], now: now) { delivered.append($0) }
        precondition(latest && delivered == ["yearly"])

        // One failed transaction must not conceal another valid subscription.
        delivered = []
        let fallback = try await V2SPremiumRecovery.deliverFirst([
            candidate(1, 300, "rejected"), candidate(1, 300, "duplicate"), candidate(2, 60, "active")
        ], now: now) {
            delivered.append($0)
            if $0 == "rejected" { throw RecoveryTestError.unavailable }
        }
        precondition(fallback && delivered == ["rejected", "active"])

        // A service outage never reports delivered access. The same unfinished
        // transaction remains retryable after restart/Restore.
        let pending = [candidate(5, 60, "retry")]
        do {
            _ = try await V2SPremiumRecovery.deliverFirst(pending, now: now) { _ in throw RecoveryTestError.unavailable }
            preconditionFailure("Failed server verification reported success")
        } catch RecoveryTestError.unavailable { }
        let retried = try await V2SPremiumRecovery.deliverFirst(pending, now: now) { delivered.append($0) }
        precondition(retried && delivered.last == "retry")

        // Cancellation must stop delivery, not fall back and grant access.
        delivered = []
        do {
            _ = try await V2SPremiumRecovery.deliverFirst([
                candidate(1, 300, "cancelled"), candidate(2, 60, "must-not-deliver")
            ], now: now) {
                delivered.append($0)
                throw CancellationError()
            }
            preconditionFailure("Cancellation was ignored")
        } catch is CancellationError { }
        precondition(delivered == ["cancelled"])
        let expired = try await V2SPremiumRecovery.deliverFirst([candidate(1, 0, "expired")], now: now) { _ in
            preconditionFailure("Expired transaction delivered")
        }
        precondition(!expired)

        precondition(V2SPurchaseInstallation(developmentSigned: true, receiptExists: false, receiptName: nil).usesTestPurchases)
        precondition(V2SPurchaseInstallation(developmentSigned: false, receiptExists: true, receiptName: "sandboxReceipt").usesTestPurchases)
        precondition(V2SPurchaseInstallation(developmentSigned: false, receiptExists: true, receiptName: "receipt") == .appStoreReceipt)
        precondition(V2SPurchaseInstallation(developmentSigned: false, receiptExists: false, receiptName: "receipt") == .unknown)
        precondition(V2SRedemptionFailure.message(for: StoreKitError.userCancelled) == nil)
        precondition(V2SRedemptionFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) == nil)
        precondition(V2SRedemptionFailure.message(for: StoreKitError.networkError(URLError(.notConnectedToInternet)))!.contains("connection"))
        precondition(V2SRedemptionFailure.message(for: StoreKitError.notAvailableInStorefront)!.contains("country or region"))
        precondition(V2SRedemptionFailure.message(for: StoreKitError.unknown)!.contains("did not return a completed redemption"))
        print("PASS: unfinished recovery, newest plan, deduplication, valid fallback, outage retry, cancellation, expiry, installation diagnostics")
        print("Controlled tests only; no Apple production redemption or server provisioning is asserted.")
    }
}
