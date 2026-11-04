import SwiftUI

struct PrivacyDisclosureView: View {

    @Environment(\.dismiss) private var dismiss

    let requiresAcknowledgement: Bool
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(AppStrings.value("Privacy before connection"),
                        systemImage: "hand.raised.fill"
                    )
                    .font(.title2.bold())

                    disclosure(
                        "How V2S handles data",
                        text: "V2S has no advertising or analytics SDK. The VPN tunnel processes traffic and DNS needed for your connection. The selected server operator may see your connecting IP and connection metadata."
                    )

                    disclosure(
                        "How your configurations are used",
                        text: "Imported proxy configurations are stored in the app’s private App Group on this device and are read to create the VPN connection. Never share screenshots that reveal configuration links or credentials."
                    )

                    disclosure(
                        "Subscription imports",
                        text: "When you import a subscription, V2S contacts that provider directly. The private URL is stored in the iOS Keychain so you can refresh it later. Imported server profiles are stored in the private App Group and can include connection credentials. The provider may see your request and has its own privacy practices."
                    )

                    disclosure(
                        "Server operators",
                        text: "You may use a server you add or a V2S-operated Premium server. Independent operators control their own service and privacy practices. Optional free-server scans contact the V2S catalog for worker-checked public servers. Availability changes; an endpoint check does not establish privacy or a working VPN tunnel."
                    )

                    disclosure(
                        "Premium purchases",
                        text: "Apple processes purchases. V2S sends an Apple-signed transaction to its verification service to activate and restore Premium access. The service maintains entitlement and operational account records. V2S does not receive your payment card details."
                    )

                    if requiresAcknowledgement {
                        Button(AppStrings.value("I Understand — Continue")) {
                            onContinue()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle(AppStrings.value("Privacy & Data"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(requiresAcknowledgement)
            .toolbar {
                if !requiresAcknowledgement {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppStrings.value("Done")) { dismiss() }
                    }
                }
            }
        }
    }

    private func disclosure(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppStrings.value(title)).font(.headline)
            Text(AppStrings.value(text)).foregroundStyle(.secondary)
        }
    }
}
