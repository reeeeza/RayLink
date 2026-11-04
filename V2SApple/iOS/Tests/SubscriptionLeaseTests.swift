import Foundation

@main struct SubscriptionLeaseTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        var lease = V2SSubscriptionLease()
        let older = lease.begin(), newer = lease.begin()
        precondition(!lease.accept(older, appleExpiry: now.addingTimeInterval(30), serverExpiry: now.addingTimeInterval(60), now: now))
        precondition(lease.accept(newer, appleExpiry: now.addingTimeInterval(30), serverExpiry: now.addingTimeInterval(60), now: now))
        precondition(lease.isActive(at: now.addingTimeInterval(29)))
        precondition(!lease.isActive(at: now.addingTimeInterval(30)))
        lease.clear()
        precondition(!lease.accept(newer, appleExpiry: now.addingTimeInterval(60), serverExpiry: now.addingTimeInterval(60), now: now))
        let renewal = lease.begin()
        precondition(lease.accept(renewal, appleExpiry: now.addingTimeInterval(120), serverExpiry: now.addingTimeInterval(45), now: now))
        precondition(lease.expiration == now.addingTimeInterval(45))
        precondition(!lease.accept(lease.begin(), appleExpiry: now, serverExpiry: now.addingTimeInterval(60), now: now))
        print("PASS: superseded response, expiry boundary, revocation race, bounded renewal")
    }
}
