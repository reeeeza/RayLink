import Foundation
import Security
import StoreKit

enum V2SRedemptionFailure {
    static func message(for error: Error) -> String? {
        if let error = error as? StoreKitError {
            switch error {
            case .userCancelled: return nil
            case .networkError:
                return "Apple's redemption service could not be reached. Check your connection. If you already redeemed the code, use Restore Purchases."
            case .notAvailableInStorefront:
                return "This offer is unavailable in your App Store country or region. Apple determines offer availability and eligibility."
            default: break
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError { return nil }
        return "Apple did not return a completed redemption. Check the message in Apple's window for code validity and eligibility. If you already redeemed the code in the App Store, use Restore Purchases. App-download promo codes do not include Premium."
    }
}

/// Installation diagnostics only. This never grants a purchase entitlement.
enum V2SPurchaseInstallation: Equatable {
    case development, testReceipt, appStoreReceipt, unknown

    init(developmentSigned: Bool, receiptExists: Bool, receiptName: String?) {
        if developmentSigned { self = .development }
        else if receiptExists && receiptName == "sandboxReceipt" { self = .testReceipt }
        else if receiptExists && receiptName == "receipt" { self = .appStoreReceipt }
        else { self = .unknown }
    }

    static func current() -> Self {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        var developmentSigned = false
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let dictionary = information as? [String: Any],
           let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            developmentSigned = entitlements["com.apple.security.get-task-allow"] as? Bool == true
        }
        let receipt = Bundle.main.appStoreReceiptURL
        return Self(developmentSigned: developmentSigned,
                    receiptExists: receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                    receiptName: receipt?.lastPathComponent)
    }

    var usesTestPurchases: Bool { self == .development || self == .testReceipt }
}

/// Only the StoreKit adapter constructs candidates, after signature, product,
/// revocation and expiry checks. The helper contains no entitlement/unlock flag.
struct V2SPremiumCandidate<Value> {
    let id: UInt64
    let expiresAt: Date
    let value: Value
}

enum V2SPremiumRecovery {
    /// Prefer the latest active period, and retry unfinished deliveries without
    /// processing a transaction twice when it occurs in both StoreKit sequences.
    @MainActor
    static func deliverFirst<Value>(
        _ candidates: [V2SPremiumCandidate<Value>], now: Date,
        deliver: (Value) async throws -> Void
    ) async throws -> Bool {
        var seen = Set<UInt64>()
        var failure: Error?
        for candidate in candidates.sorted(by: { $0.expiresAt > $1.expiresAt }) {
            guard candidate.expiresAt > now, seen.insert(candidate.id).inserted else { continue }
            do {
                try await deliver(candidate.value)
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch { failure = error }
        }
        if let failure { throw failure }
        return false
    }
}
