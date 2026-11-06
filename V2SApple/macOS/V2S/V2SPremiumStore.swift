import Foundation
import Combine
import StoreKit

@MainActor
final class V2SPremiumStore: ObservableObject {
    static let shared = V2SPremiumStore()

    static let monthlyProductID = "ca.irisbuddy.v2s.premium.monthly"
    static let yearlyProductID = "ca.irisbuddy.v2s.premium.yearly"
    private static let productIDs = [monthlyProductID, yearlyProductID]
    let installation = V2SPurchaseInstallation.current()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isCheckingEntitlement = false
    @Published private(set) var hasCheckedEntitlement = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var purchaseWaitMessage: String?
    @Published private(set) var completedPurchaseProductID: String?
    @Published private(set) var isEntitled = false
    @Published private(set) var activeProductID: String?
    @Published private(set) var expirationDate: Date?
    @Published private(set) var message = "Apple subscriptions are being prepared."
    @Published private(set) var premiumProfiles: [V2SProfile] = []

    private var updatesTask: Task<Void, Never>?
    private var leaseTask: Task<Void, Never>?
    private var revalidationTask: Task<Void, Never>?
    private var purchaseNoticeTask: Task<Void, Never>?
    private var lease = V2SPremiumLease()

    private init() {}

    private func startObserving() {
        guard V2SPrivacyConsent.shared.accepted, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.process(update)
            }
        }
        leaseTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                ticks += 1
                // Date is checked after wake as well as during normal operation.
                let expired = self.isEntitled && !self.lease.isActive(at: .now)
                if expired {
                    self.clearAccess(message: "Premium access expired. Checking for renewal…")
                    ticks = 60
                }
                if (expired || ticks >= 60), !self.isCheckingEntitlement,
                   self.purchasingProductID == nil {
                    ticks = 0
                    // Keep the expiry clock running while network verification
                    // waits; a slow request must never extend the current lease.
                    self.revalidationTask = Task { [weak self] in
                        await self?.refreshEntitlement()
                    }
                }
            }
        }
    }

    deinit { updatesTask?.cancel(); leaseTask?.cancel(); revalidationTask?.cancel(); purchaseNoticeTask?.cancel() }

    func withdrawPrivacyConsent() {
        updatesTask?.cancel()
        updatesTask = nil
        leaseTask?.cancel()
        leaseTask = nil
        revalidationTask?.cancel()
        V2SPremiumAPI.cancelRequests()
        clearAccess(message: "Agree to the privacy disclosure before using Premium.")
        products = []
        hasCheckedEntitlement = false
    }

    func load() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        startObserving()
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        await loadProducts()
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
        await refreshEntitlement()
    }

    func loadProducts() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isLoadingProducts else { return }
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
                .filter { $0.type == .autoRenewable }
                .sorted {
                    let left = Self.productIDs.firstIndex(of: $0.id) ?? 99
                    let right = Self.productIDs.firstIndex(of: $1.id) ?? 99
                    return left < right
                }
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
            products = loaded
            if products.isEmpty {
                message = "Monthly and yearly plans are not available in the App Store yet."
            } else if !isEntitled {
                // A previous empty/error result must not remain visible after
                // StoreKit successfully returns the configured products.
                message = "Choose a monthly or yearly plan to unlock V2S Premium Servers."
            }
        } catch {
            message = "V2S could not load Apple subscription plans. Try again later."
        }
    }

    func purchase(_ product: Product) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        // StoreKit handles a change between plans in the same subscription group.
        // An active monthly entitlement must not silently block the yearly plan.
        guard Self.productIDs.contains(product.id), purchasingProductID == nil,
              hasCheckedEntitlement, !isCheckingEntitlement else { return }
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        purchasingProductID = product.id
        purchaseWaitMessage = nil
        completedPurchaseProductID = nil
        purchaseNoticeTask?.cancel()
        purchaseNoticeTask = Task { [weak self, productID = product.id] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.purchasingProductID == productID else { return }
            self.purchaseWaitMessage = "Waiting for Apple's purchase window. Check your App Store account; if no window appears, reopen V2S and try again."
        }
        defer {
            purchaseNoticeTask?.cancel()
            purchaseNoticeTask = nil
            purchasingProductID = nil
            purchaseWaitMessage = nil
        }
        do {
            let result = try await product.purchase()
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
            switch result {
            case .success(let verification):
                try await deliver(verification)
                completedPurchaseProductID = product.id
            case .pending:
                message = "The purchase is awaiting approval. V2S will check again when Apple confirms it."
            case .userCancelled:
                message = "Purchase cancelled."
            @unknown default:
                message = "Apple returned an unsupported purchase result."
            }
        } catch is CancellationError {
            // A more recent verification or revocation superseded this response.
        } catch let error as PremiumError {
            message = error.localizedDescription
        } catch {
            message = "V2S could not complete the Apple subscription purchase. Try again."
        }
    }

    func restore() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isCheckingEntitlement else { return }
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        isCheckingEntitlement = true
        defer {
            isCheckingEntitlement = false
            if V2SPrivacyConsent.shared.permits(privacyTicket) { hasCheckedEntitlement = true }
        }
        // CurrentEntitlements already includes a locally known active purchase.
        // Revalidate it first so Restore does not wait on AppStore.sync() when
        // there is nothing new for Apple to synchronize.
        await refreshCurrentEntitlement(privacyTicket: privacyTicket)
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
        if isEntitled { return }
        do {
            try await AppStore.sync()
            await refreshCurrentEntitlement(privacyTicket: privacyTicket, restoring: true)
        } catch {
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
            clearAccess(message: "V2S could not sync purchases with Apple. Check your connection and try Restore again.")
        }
    }

    /// Revalidates with the V2S service before premium profiles can be used.
    /// A device-side StoreKit entitlement on its own never grants server access.
    @discardableResult
    func refreshEntitlement(redeemedTransaction: VerificationResult<Transaction>? = nil) async -> Bool {
        guard V2SPrivacyConsent.shared.accepted else { return false }
        // Serialize with background verification and Restore. Never return a
        // stale entitlement, or reject a valid subscriber merely because a
        // periodic check is already in flight.
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while isCheckingEntitlement {
            guard ContinuousClock.now < deadline,
                  V2SPrivacyConsent.shared.permits(privacyTicket),
                  !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        guard V2SPrivacyConsent.shared.permits(privacyTicket), !Task.isCancelled else { return false }
        isCheckingEntitlement = true
        defer {
            isCheckingEntitlement = false
            if V2SPrivacyConsent.shared.permits(privacyTicket) { hasCheckedEntitlement = true }
        }
        if let redeemedTransaction {
            // macOS 27 supplies the transaction in the redemption completion.
            // Do not discard it and race a currentEntitlements snapshot which
            // may still be empty. Delivery verifies Apple and the V2S service
            // before publishing access and finishing the transaction.
            do { try await deliver(redeemedTransaction) }
            catch is CancellationError { return false }
            catch {
                // A rejected offer must not erase a separately valid existing
                // subscription. Revalidate that access through the usual path.
                await refreshCurrentEntitlement(privacyTicket: privacyTicket)
                if !isEntitled {
                    message = "V2S could not verify Premium access from this redemption. No new access was granted. Try Restore Purchases to retry verification."
                }
                return false
            }
        } else {
            await refreshCurrentEntitlement(privacyTicket: privacyTicket)
        }
        return isEntitled && (expirationDate.map { $0 > .now } ?? false)
    }

    // The public refresh and Restore flows both hold the entitlement-check
    // guard before entering this helper.
    private func refreshCurrentEntitlement(privacyTicket: UInt64?, restoring: Bool = false) async {
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
        var candidates: [V2SPremiumCandidate<VerificationResult<Transaction>>] = []
        for await result in Transaction.currentEntitlements {
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
            if let candidate = activeCandidate(result) { candidates.append(candidate) }
        }
        // A redeemed transaction can remain unfinished if a previous launch or
        // server verification was interrupted. Retry it, without redeeming or
        // asking Apple to synchronize/authenticate on every launch.
        for await result in Transaction.unfinished {
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
            if let candidate = activeCandidate(result) { candidates.append(candidate) }
        }
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
        do {
            if try await V2SPremiumRecovery.deliverFirst(candidates, now: .now, deliver: { result in
                try await self.deliver(result)
            }) { return }
        } catch is CancellationError { return }
        catch {
            clearAccess(message: "Apple shows a subscription, but V2S could not verify server access. Try Restore Purchases to retry verification.")
            return
        }
        clearAccess(message: restoring
                ? "No active V2S Premium subscription was found for this Apple Account. Check that this Mac uses the same purchase account and Store environment, then try Restore again."
                : "Subscribe to unlock V2S Premium Servers.")
        if products.isEmpty && !restoring {
            message = "Monthly and yearly plans are not available in the App Store yet."
        }
    }

    private func activeCandidate(_ result: VerificationResult<Transaction>) -> V2SPremiumCandidate<VerificationResult<Transaction>>? {
        guard case .verified(let transaction) = result,
              Self.productIDs.contains(transaction.productID),
              transaction.revocationDate == nil,
              let expiry = transaction.expirationDate, expiry > .now else { return nil }
        return V2SPremiumCandidate(id: transaction.id, expiresAt: expiry, value: result)
    }

    private func process(_ result: VerificationResult<Transaction>) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        if activeCandidate(result) != nil {
            // Use the same serialized path as redemption and Restore, so a
            // delayed snapshot cannot clear a concurrently delivered purchase.
            await refreshEntitlement(redeemedTransaction: result)
        } else {
            // Revocation/expiry may refer to an old period after a renewal.
            // Reconcile the account rather than overwriting the newer period.
            await refreshEntitlement()
        }
    }

    private func clearAccess(message: String) {
        lease.invalidate()
        isEntitled = false
        activeProductID = nil
        expirationDate = nil
        premiumProfiles = []
        self.message = message
    }

    private func deliver(_ result: VerificationResult<Transaction>) async throws {
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        let transaction: Transaction
        switch result {
        case .verified(let verified): transaction = verified
        case .unverified: throw PremiumError.unverified
        }
        guard Self.productIDs.contains(transaction.productID),
              transaction.revocationDate == nil,
              let appleExpiry = transaction.expirationDate, appleExpiry > .now else { throw PremiumError.inactive }

        let revision = lease.beginVerification()
        let response: V2SPremiumAPI.Response
        do {
            response = try await V2SPremiumAPI.verify(transactionJWS: result.jwsRepresentation)
        } catch {
            guard revision == lease.revision, V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
            throw error
        }
        guard revision == lease.revision, V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        guard response.active, response.productID == transaction.productID,
              let serverExpiry = response.expirationDate, serverExpiry > .now,
              !response.entries.isEmpty else { throw PremiumError.serverRejected }

        let accessExpiry = min(serverExpiry, appleExpiry)
        // The verified service supplies the available catalog. Location fields
        // are presentation data, never a country restriction on user imports.
        let profiles = try response.entries.prefix(100).map { entry -> V2SProfile in
            var profile = try V2SXray.makeProfile(from: entry.uri)
            profile.name = entry.name.isEmpty ? "Premium server" : entry.name
            profile.countryCode = entry.country_code?.uppercased()
            profile.city = entry.city
            profile.isV2SOperated = true
            profile.isPremium = true
            return profile
        }
        guard !profiles.isEmpty,
              lease.accept(revision: revision, expiresAt: accessExpiry, now: .now)
        else { throw PremiumError.serverRejected }
        premiumProfiles = profiles
        isEntitled = true
        activeProductID = transaction.productID
        expirationDate = accessExpiry
        let expiry = accessExpiry.formatted(date: .abbreviated, time: .shortened)
        message = transaction.environment == .sandbox
            ? "Sandbox test access is active until \(expiry). Test renewals are accelerated."
            : "Premium server access is active until \(expiry)."
        await transaction.finish()
    }

    fileprivate enum PremiumError: LocalizedError {
        case unverified, inactive, serverRejected
        var errorDescription: String? {
            switch self {
            case .unverified: "Apple could not verify this purchase. No premium server access was granted."
            case .inactive: "This Apple subscription is not active."
            case .serverRejected: "The V2S service did not confirm an active premium subscription and server profile."
            }
        }
    }
}

@MainActor
private enum V2SPremiumAPI {
    private static var session = URLSession(configuration: .ephemeral)
    static func cancelRequests() {
        session.invalidateAndCancel()
        session = URLSession(configuration: .ephemeral)
    }
    private static let verificationURL = URL(string: "https://hostinger.v2teh.com/v2s/api/v1/apple/verify")!
    private struct Request: Encodable { let signedTransactionInfo: String }
    fileprivate struct Response: Decodable {
        struct Entry: Decodable {
            let uri: String
            let name: String
            let country_code: String?
            let city: String?
        }
        let status: String
        let product_id: String
        let subscription_expires_at: Int64
        let entries: [Entry]

        var active: Bool { status == "active" }
        var productID: String { product_id }
        var expirationDate: Date? { Date(timeIntervalSince1970: TimeInterval(subscription_expires_at)) }
    }

    fileprivate static func verify(transactionJWS: String) async throws -> Response {
        var request = URLRequest(url: verificationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = try JSONEncoder().encode(Request(signedTransactionInfo: transactionJWS))
        let (data, result) = try await session.data(for: request)
        guard let response = result as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 512 * 1024 else { throw V2SPremiumStore.PremiumError.serverRejected }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw V2SPremiumStore.PremiumError.serverRejected }
    }
}
