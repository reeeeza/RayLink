import Foundation
import StoreKit
import Combine

/// iOS billing is intentionally independent of the macOS purchase UI.
/// Apple verifies the transaction on-device; our service must also verify it
/// for this iOS bundle before returning customer-specific VPN configurations.
@MainActor
final class V2SSubscriptions: ObservableObject {
    static let shared = V2SSubscriptions()
    static let monthlyID = "ca.irisbuddy.v2s.premium.monthly"
    static let yearlyID = "ca.irisbuddy.v2s.premium.yearly"
    private static let ids: Set<String> = [monthlyID, yearlyID]
    private static let verificationURL = URL(string: "https://hostinger.v2teh.com/v2s/api/v1/apple/verify")!

    @Published private(set) var products: [Product] = []
    @Published private(set) var profiles: [ProxyProfile] = []
    @Published private(set) var expiration: Date?
    @Published private(set) var isWorking = false
    @Published var message: String?

    private var updates: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var lease = V2SSubscriptionLease()
    var isActive: Bool { lease.isActive(at: .now) && !profiles.isEmpty }
    private var hasPrivacyConsent: Bool { UserDefaults.standard.bool(forKey: "v2tah.hasAcknowledgedPrivacy") }

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await self.refresh()
                    await transaction.finish()
                }
            }
        }
        expiryTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                ticks += 1
                if self.expiration != nil && !self.lease.isActive(at: .now) {
                    self.clearAccess()
                    ticks = 60
                }
                if ticks >= 60 && !self.isWorking {
                    ticks = 0
                    await self.refresh()
                }
            }
        }
    }

    deinit { updates?.cancel(); expiryTask?.cancel() }

    func prepare() async {
        guard hasPrivacyConsent else { return }
        do {
            products = try await Product.products(for: Self.ids).sorted { $0.id < $1.id }
        } catch {
            message = "Subscription plans are temporarily unavailable."
        }
        await refresh()
    }

    func purchase(_ product: Product) async {
        guard hasPrivacyConsent, Self.ids.contains(product.id), !isWorking else { return }
        isWorking = true
        let ticket = lease.begin()
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    throw BillingError.unverified
                }
                try await apply(transaction, signedTransaction: result.jwsRepresentation, ticket: ticket)
                await transaction.finish()
            case .pending:
                message = "Apple is still processing this purchase. Access will update when it is approved."
            case .userCancelled:
                break
            @unknown default:
                message = "Apple returned an unknown purchase result."
            }
        } catch is CancellationError {
            // A newer renewal or revocation superseded this purchase response.
        } catch {
            message = "Premium access could not be activated. Please try Restore Purchases."
        }
    }

    func restore() async {
        guard hasPrivacyConsent, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refresh()
            if profiles.isEmpty { message = "No active V2S Premium subscription was found or verified." }
        } catch {
            message = "Restore Purchases could not finish. Please try again."
        }
    }

    func refresh() async {
        guard hasPrivacyConsent else { clearAccess(); return }
        let ticket = lease.begin()
        var candidates: [(Transaction, String)] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.ids.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantPast) > .now
            else { continue }
            candidates.append((transaction, result.jwsRepresentation))
        }
        candidates.sort { ($0.0.expirationDate ?? .distantPast) > ($1.0.expirationDate ?? .distantPast) }
        for (transaction, signedTransaction) in candidates {
            guard lease.permits(ticket), !Task.isCancelled else { return }
            if (try? await apply(transaction, signedTransaction: signedTransaction, ticket: ticket)) != nil { return }
        }
        guard lease.permits(ticket), !Task.isCancelled else { return }
        clearAccess()
    }

    private func clearAccess() {
        lease.clear()
        profiles = []
        expiration = nil
    }

    func resetLocalState() { clearAccess(); message = nil }

    private func apply(_ transaction: Transaction, signedTransaction: String, ticket: UInt64) async throws {
        guard Self.ids.contains(transaction.productID),
              transaction.revocationDate == nil,
              let appleExpiry = transaction.expirationDate,
              appleExpiry > .now
        else { throw BillingError.inactive }

        var request = URLRequest(url: Self.verificationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(VerificationRequest(signedTransactionInfo: signedTransaction))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard hasPrivacyConsent, lease.permits(ticket), !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 512 * 1024
        else { throw BillingError.serviceUnavailable }
        let verified = try JSONDecoder().decode(VerificationResponse.self, from: data)
        guard verified.status == "active",
              verified.product_id == transaction.productID,
              verified.subscription_expires_at > Int64(Date.now.timeIntervalSince1970),
              !verified.entries.isEmpty
        else { throw BillingError.inactive }
        let parsed = try verified.entries.prefix(30).map { entry -> ProxyProfile in
            var profile = try ConfigurationParser.parse(entry.uri)
            profile.name = entry.name
            profile.sourceName = "V2S Premium"
            if let previous = profiles.first(where: { $0.server == profile.server && $0.port == profile.port && $0.protocolType == profile.protocolType && $0.uuid == profile.uuid && $0.password == profile.password }) {
                profile.id = previous.id
            }
            return profile
        }
        guard lease.accept(ticket, appleExpiry: appleExpiry,
            serverExpiry: Date(timeIntervalSince1970: TimeInterval(verified.subscription_expires_at)), now: .now) else { throw CancellationError() }
        profiles = parsed
        expiration = lease.expiration
        message = nil
    }

    private struct VerificationRequest: Encodable { let signedTransactionInfo: String }
    private struct VerificationResponse: Decodable {
        struct Entry: Decodable { let uri: String; let name: String }
        let status: String
        let product_id: String
        let subscription_expires_at: Int64
        let entries: [Entry]
    }
    private enum BillingError: Error { case unverified, inactive, serviceUnavailable }
}
