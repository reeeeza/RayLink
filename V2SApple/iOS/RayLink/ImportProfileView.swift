import SwiftUI
import UIKit

struct ImportProfileView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var configurationText: String
    @State private var errorMessage: String?
    @State private var isImporting = false

    let onImported: () -> Void

    init(
        initialConfiguration: String = "",
        onImported: @escaping () -> Void
    ) {
        _configurationText = State(initialValue: initialConfiguration)
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $configurationText)
                        .frame(minHeight: 180)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label(AppStrings.value("Paste from Clipboard"), systemImage: "doc.on.clipboard")
                    }
                    .disabled(isImporting)
                } header: {
                    Text(AppStrings.value("Server or Subscription Link"))
                } footer: {
                    Text(AppStrings.value("Paste a VLESS, VMess, Trojan, or Shadowsocks link, "
                        + "a list of links, or a secure HTTPS subscription URL. "
                        + "Subscription links can contain private access tokens; do not share them.")
                    )
                }

                Section {
                    Button {
                        Task { await importConfiguration() }
                    } label: {
                        HStack {
                            Spacer()

                            if isImporting {
                                ProgressView()
                            } else {
                                Label(AppStrings.value("Import Servers"),
                                    systemImage: "square.and.arrow.down"
                                )
                                .fontWeight(.semibold)
                            }

                            Spacer()
                        }
                    }
                    .disabled(trimmedConfiguration.isEmpty || isImporting)
                }
            }
            .navigationTitle(AppStrings.value("Add Servers"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isImporting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.value("Cancel")) { dismiss() }
                        .disabled(isImporting)
                }
            }
            .alert(AppStrings.value("Cannot Import Servers"), isPresented: errorBinding) {
                Button(AppStrings.value("OK")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var trimmedConfiguration: String {
        configurationText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func importConfiguration() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let savedProfiles: [ProxyProfile]

            if SubscriptionImporter.isSubscriptionURL(trimmedConfiguration) {
                let imported = try await SubscriptionImporter
                    .importSubscription(from: trimmedConfiguration)
                let result = try SubscriptionStore.saveImport(
                    urlString: trimmedConfiguration,
                    profiles: imported.profiles,
                    usage: imported.usage
                )
                savedProfiles = result.1
                SafeLogStore.append("Subscription imported with \(result.1.count) supported servers")
            } else {
                let importedProfiles = try await SubscriptionImporter
                    .importProfiles(from: trimmedConfiguration)
                _ = try SharedConfiguration.add(profiles: importedProfiles)
                savedProfiles = importedProfiles
                SafeLogStore.append("\(importedProfiles.count) server configuration(s) imported")
            }

            if let firstProfile = savedProfiles.first {
                try SharedConfiguration.save(profile: firstProfile)
            }

            onImported()
            dismiss()
        } catch {
            // Import errors are intentionally credential-safe.
            errorMessage = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        guard let clipboardText = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty
        else {
            errorMessage = "The Clipboard does not contain a server or subscription link."
            return
        }

        configurationText = clipboardText
    }
}
