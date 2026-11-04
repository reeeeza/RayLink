import SwiftUI
import StoreKit

struct V2SPremiumPlansView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var billing = V2SSubscriptions.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingOfferCodeRedemption = false

    var body: some View {
        NavigationStack {
            List {
                if billing.profiles.isEmpty {
                    Section {
                        Text(AppStrings.value("Choose a location after your subscription is active. Your own servers remain free to use."))
                            .foregroundStyle(.secondary)
                    }
                    Section(AppStrings.value("Plans")) {
                        if billing.products.isEmpty {
                            Text(AppStrings.value("Plans are currently unavailable. Please try again later."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(billing.products, id: \.id) { product in
                            Button {
                                Task { await billing.purchase(product) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(AppStrings.value(product.id == V2SSubscriptions.yearlyID ? "Yearly" : "Monthly"))
                                            .font(.headline)
                                        Text(AppStrings.value(
                                            product.id == V2SSubscriptions.yearlyID
                                                ? "Access Premium servers for one year."
                                                : "Access Premium servers every month."
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(product.displayPrice)
                                        .font(.headline)
                                }
                            }
                            .disabled(billing.isWorking)
                        }
                    }
                }
                Section {
                    Button(AppStrings.value("Redeem offer code")) { showingOfferCodeRedemption = true }
                        .disabled(billing.isWorking)
                    Text(AppStrings.value("Redeem a V2S Premium Monthly or Yearly subscription offer code. Apple shows the free or discounted period and renewal terms before confirmation. App-download promo codes do not include Premium."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(AppStrings.value("Restore Purchases")) { Task { await billing.restore() } }
                        .disabled(billing.isWorking)
                    if let expiration = billing.expiration, !billing.profiles.isEmpty {
                        Text(AppStrings.format(
                            "Premium access active until %@",
                            [expiration.formatted(date: .abbreviated, time: .shortened)]
                        ))
                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                            Text(AppStrings.value("Manage Subscription"))
                        }
                    }
                }
                Section {
                    Text(AppStrings.value("Subscriptions renew automatically unless cancelled. Apple shows the final price, trial eligibility and renewal terms before you confirm. Manage or cancel in your Apple Account."))
                        .font(.footnote)
                    Text("راهنمای فارسی: V2S یک کلاینت VPN و پروکسی برای VLESS، VMess، Trojan و Shadowsocks است. سرورهای Premium به اشتراک معتبر نیاز دارند. موقعیت‌های قابل انتخاب، از جمله ایران در صورت موجود بودن، در فهرست سرورها نمایش داده می‌شوند. اتصال به شبکه یا خدمات بانکی ایران به سرور، اینترنت و مقررات بانک بستگی دارد و تضمین نمی‌شود. کد پیشنهاد اشتراک را با «Redeem offer code» وارد کنید؛ مدت رایگان و شرایط تمدید را اپل نمایش می‌دهد.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .rightToLeft)
                    Link(destination: URL(string: "https://v2teh.com/v2s-ios-privacy.html")!) {
                        Text(AppStrings.value("Privacy Policy"))
                    }
                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        Text(AppStrings.value("Terms of Use"))
                    }
                }
            }
            .navigationTitle(AppStrings.value("V2S Premium"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppStrings.value("Done")) { dismiss() } } }
            .task { await billing.prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await billing.refresh() } }
            }
            .offerCodeRedemption(isPresented: $showingOfferCodeRedemption) { result in
                switch result {
                case .success: Task { await billing.refresh() }
                case .failure(let error):
                    if case .userCancelled = error as? StoreKitError { return }
                    billing.message = "Apple could not complete code redemption. Check that this is a V2S Premium subscription offer code, then try again."
                }
            }
            .alert(AppStrings.value("V2S Premium"), isPresented: Binding(
                get: { billing.message != nil },
                set: { if !$0 { billing.message = nil } }
            )) { Button(AppStrings.value("OK")) { billing.message = nil } } message: { Text(billing.message ?? "") }
        }
    }
}
