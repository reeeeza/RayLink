import Foundation
@main struct PrivacyPermissionTests {
    static func main() {
        var state = V2SPrivacyPermission(accepted: false)
        precondition(state.ticket == nil && !state.permits(nil))
        state.setAccepted(true)
        let inFlight = state.ticket
        precondition(state.permits(inFlight))
        state.setAccepted(false)
        precondition(!state.permits(inFlight) && state.ticket == nil)
        state.setAccepted(true)
        precondition(!state.permits(inFlight))
        precondition(state.permits(state.ticket))
        let resumed = state.ticket
        state.setAccepted(false)
        precondition(!state.permits(resumed))
        print("PASS: first-run denial, accepted request, revocation, stale completion after re-consent")
    }
}
