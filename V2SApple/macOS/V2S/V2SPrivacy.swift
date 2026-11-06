import Foundation

// An operation keeps its original permission even if consent is later granted
// again. A revoke/accept cycle must not revive an older in-flight response.
struct V2SPrivacyPermission: Equatable, Sendable {
    private(set) var accepted: Bool
    private(set) var generation: UInt64 = 0
    var ticket: UInt64? { accepted ? generation : nil }
    mutating func setAccepted(_ value: Bool) { generation &+= 1; accepted = value }
    func permits(_ ticket: UInt64?) -> Bool { accepted && ticket == generation }
}

#if !V2S_PRIVACY_TEST
import SwiftUI

@MainActor
final class V2SPrivacyConsent: ObservableObject {
    static let shared = V2SPrivacyConsent()
    static let version = 2
    private static let key = "v2s.privacy.acceptedVersion"
    @Published private(set) var permission: V2SPrivacyPermission
    var accepted: Bool { permission.accepted }
    var ticket: UInt64? { permission.ticket }
    func permits(_ ticket: UInt64?) -> Bool { permission.permits(ticket) }

    private init() {
        permission = V2SPrivacyPermission(accepted: UserDefaults.standard.integer(forKey: Self.key) == Self.version)
    }
    func accept() {
        UserDefaults.standard.set(Self.version, forKey: Self.key)
        permission.setAccepted(true)
    }
    func revoke() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        permission.setAccepted(false)
    }
}

struct V2SPrivacyGate<Content: View>: View {
    @ObservedObject private var consent = V2SPrivacyConsent.shared
    @ObservedObject var model: V2SViewModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if consent.accepted { content() }
            else { V2SPrivacyView(model: model, requiresConsent: true) }
        }
    }
}

struct V2SPrivacyView: View {
    @ObservedObject var model: V2SViewModel
    var requiresConsent = false
    @State private var showingFullPolicy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if requiresConsent {
                    Picker(V2SLocalization.text("Language"), selection: Binding(
                        get: { model.settings.languageCode ?? "en" },
                        set: { code in var settings = model.settings; settings.languageCode = code; model.updateSettings(settings) }
                    )) {
                        ForEach(V2SLocalization.languages, id: \.code) { language in
                            Text(verbatim: language.name).tag(language.code)
                        }
                    }.frame(maxWidth: 360)
                }
                Label(V2SLocalization.text("Your privacy in V2S"), systemImage: "hand.raised.fill")
                    .font(.system(size: 26, weight: .bold))
                Text(V2SLocalization.text("Before using network features or purchasing Premium, review how V2S handles your information."))
                    .font(.title3).foregroundStyle(V2SPalette.secondaryText)
                disclosure("VPN traffic", "V2S processes network traffic, destination addresses and DNS requests to connect through your chosen server. The operator can see connection metadata and traffic that is not separately encrypted. V2S operates its Premium service; imported and public servers have their own operators.")
                disclosure("Profiles, subscriptions and checks", "Private server credentials and subscription links are kept in this Mac’s Keychain. Subscription providers receive refresh requests. Server checks contact selected endpoints, and proxy checks use Cloudflare or Google connectivity URLs. Optional public discovery contacts the V2S feed service; it does not upload your private profiles.")
                disclosure("Optional public servers", V2SPublicServerNotice.text)
                disclosure("Apple purchases", "Apple handles billing. V2S sends your Apple-signed transaction to its service to verify Premium access. The service retains a subscription identifier digest, account mapping, status and expiry, and the credentials needed to operate your Premium account. Service ingress may log request IP metadata.")
                Text(V2SLocalization.text("V2S does not sell VPN data or use or disclose it to third parties for purposes other than providing the VPN service. V2S does not promise that independently operated servers keep no logs."))
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(V2SLocalization.text("Read the full Mac privacy policy"), isExpanded: $showingFullPolicy) {
                    Text(V2SLocalization.text(V2SMacPrivacyPolicy.text)).font(.system(size: 14))
                        .textSelection(.enabled).padding(.top, 12)
                }
                Link(V2SLocalization.text("Privacy questions and requests"), destination: URL(string: "https://v2teh.com/contact.html")!)
                if requiresConsent {
                    if let issue = model.privacyStopError {
                        Text(V2SLocalization.text(issue)).foregroundStyle(V2SPalette.error)
                        Button(V2SLocalization.text("Retry stopping V2S")) { model.withdrawPrivacyConsent() }
                    }
                    Text(V2SLocalization.text("You can withdraw consent in Settings. This stops V2S network features and disconnects its VPN. Requests already in progress may finish. Withdrawing does not cancel your Apple subscription or delete remote records."))
                        .foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button(V2SLocalization.text("Decline and quit")) { NSApplication.shared.terminate(nil) }
                            .disabled(model.isChangingPrivacyConsent)
                        Spacer()
                        Button(V2SLocalization.text(model.isChangingPrivacyConsent ? "Stopping V2S…" : "Agree and continue")) {
                            model.acceptPrivacyConsent()
                        }
                        .buttonStyle(.borderedProminent).disabled(model.isChangingPrivacyConsent || model.privacyStopError != nil)
                    }
                }
            }
            .padding(30).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .font(.system(size: 15)).foregroundStyle(V2SPalette.text)
        .background(V2SPalette.background).preferredColorScheme(.dark).tint(V2SPalette.cyan)
    }
    private func disclosure(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(V2SLocalization.text(title)).font(.headline).foregroundStyle(V2SPalette.cyan)
            Text(V2SLocalization.text(detail)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum V2SPublicServerNotice {
    static let text = """
    Scanning contacts the V2S feed, independent servers, and Cloudflare or Google test services. They can receive your request IP and connection metadata. When you connect, the server operator may also see traffic that is not separately encrypted. Private profiles are not uploaded to the feed.

    A response test does not verify an operator’s identity, privacy practices, security, location, or permission to share a server. Avoid sensitive accounts and private information. Use only services you are authorized to access and follow applicable laws and provider terms. Listing does not imply endorsement by V2S or Apple.

    If enabled, automatic scans continue while V2S is open and disconnected. Turn off public discovery in Settings to stop future scans. Report suspected unauthorized listings through the contact form at https://v2teh.com/contact.html.
    """
}

enum V2SOpenSourceNotices {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License notices could not be loaded. Please use the contact form at https://v2teh.com/contact.html."
        }
        return text
    }()
}

enum V2SMacPrivacyPolicy {
    static let text = """
    V2S for macOS — Privacy Policy
    Effective 25 September 2026 · Contact: https://v2teh.com/contact.html

    VPN service
    V2S uses Apple NetworkExtension and the embedded Xray engine to process network traffic, destination addresses and DNS requests and send traffic through your selected server. V2S operates the Premium VPN service. Imported subscription and public servers may be independently operated. The selected operator can observe connection metadata and traffic without separate end-to-end encryption. Excluded local networks use your ordinary connection. The tunnel can continue while the app is closed, depending on macOS and your settings.

    V2S does not sell VPN data or use or disclose it to third parties for purposes other than providing the VPN service. Encryption does not guarantee anonymity. Consult independent server operators about their handling and retention of your information.

    Local profiles and settings
    Server credentials, subscription URLs and settings are stored in the shared app/extension Keychain with device-only accessibility after the first unlock. Operational flags and refresh timestamps are stored in app preferences. Private profiles are not sent to the public discovery feed. Removing the app may leave Keychain items; remove saved profiles and subscriptions inside V2S to delete those entries. This does not delete information retained by providers.

    Subscription refresh and connectivity checks
    Your subscription provider receives HTTPS requests, including any credentials embedded in the URL, your request IP and the V2S user agent. Refreshes may occur while the app is open according to your settings. Delete a subscription or disable automatic refresh to stop future scheduled requests. Reachability checks contact configured hosts; proxy checks send connectivity requests through the selected server to Cloudflare or Google. These operators receive the request and its network metadata. Checks are not proof of a server's location or privacy practices.

    Optional public discovery
    When enabled, V2S requests public candidates from the V2S feed service, then checks them from your Mac. The service and shared HTTPS ingress can receive your IP address and user agent. The service probes public endpoints and keeps temporary public-link caches. Private imported profiles are not uploaded. Public-server operators and connectivity-test providers can observe the requests made through them. Disable discovery in Settings to stop future requests. This Mac version checks for refreshes at thirty-minute intervals while open, subject to connection state. Public servers are independently operated and may be unsuitable for sensitive activity.

    Public-server use and rights
    A successful connectivity test is not verification of the operator’s identity, security, privacy practices, location, or right to share a configuration. Do not use public servers for sensitive accounts or private information. Only access services you are authorized to use, and comply with applicable laws and provider terms. Public availability alone does not grant permission to redistribute a configuration. Listing a server does not imply endorsement by V2S or Apple, and Apple does not operate these servers. Availability and performance may change without notice.

    To report a suspected unauthorized listing, copyright concern or abuse, use the contact form at https://v2teh.com/contact.html with the public source, the basis of your concern and a way to contact you. Do not send private keys, passwords or full subscription URLs. V2S will assess reports and can remove listings or sources. These notices do not replace V2S’s own obligations, grant third-party rights, or limit rights that cannot lawfully be excluded.

    App terms and copyright
    Copyright © 2026 Irisholdingsbuddy Inc. Third-party components and materials remain subject to their respective licenses and rights. Use of the Mac app is governed by Apple’s Standard End User License Agreement: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/. This privacy policy explains data handling; it is not a promise of anonymity or a waiver of statutory consumer rights.

    Apple billing and Premium accounts
    Apple handles payment details, trial eligibility, renewal and cancellation. V2S does not receive your card number. For Premium access the app sends an Apple-signed transaction over HTTPS to the V2S service, which verifies it with Apple. The service retains a digest of the original transaction identifier, its account mapping, product, entitlement state and expiry. It retains the VPN account credentials needed to provide access and disables expired access. Signed transactions are processed for verification rather than stored as purchase records in the V2S entitlement database. Apple's server notifications are verified and used to update access; notification identifiers are retained to avoid duplicate processing. Service ingress may log IP/request metadata. Tokens, signed transactions and profile credentials are not intentionally written to app or gateway logs.

    Retention, deletion and controls
    Imported local data remains until removed. The app keeps up to 200 diagnostic events in memory per session with URL/credential redaction; Clear in Activity removes that buffer. Local deletion or uninstalling does not erase server-side entitlement, operational or provider records. Use the contact form at https://v2teh.com/contact.html for V2S Premium account deactivation or deletion requests; ownership verification may be required. No automatic deletion deadline is promised in this version. Contact independent providers for their records. Manage or cancel billing through your Apple Account; account deletion, withdrawing consent and uninstalling do not cancel an Apple subscription.

    Withdraw consent in Settings to stop V2S network features, disable its automatic connection rules and disconnect its tunnel. Requests already in progress may finish. You can read this policy before granting consent again. Apple and other providers retain information under their own policies. This policy describes the Mac version; Android uses Google Play verification and different local storage and controls.

    Support
    Send privacy questions through the contact form at https://v2teh.com/contact.html. Do not include private server keys, passwords, transaction records or subscription URLs. Changes to data handling will be reflected in an updated policy and renewed disclosure where appropriate.
    """
}
#endif
