import Foundation

/// Rejects superseded verification responses and never extends Apple's expiry.
struct V2SSubscriptionLease {
    private(set) var generation: UInt64 = 0
    private(set) var expiration: Date?
    mutating func begin() -> UInt64 { generation &+= 1; return generation }
    func permits(_ ticket: UInt64) -> Bool { ticket == generation }
    mutating func clear() { generation &+= 1; expiration = nil }
    mutating func accept(_ ticket: UInt64, appleExpiry: Date, serverExpiry: Date, now: Date) -> Bool {
        let expiry = min(appleExpiry, serverExpiry)
        guard permits(ticket), expiry > now else { return false }
        expiration = expiry
        return true
    }
    func isActive(at now: Date) -> Bool { expiration.map { $0 > now } ?? false }
}
