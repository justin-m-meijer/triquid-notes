import SwiftUI
import UniformTypeIdentifiers

/// Client certificate (mutual TLS) and trusted self-signed server certificate for one server.
/// Reached from the login screen (Advanced) and from Settings › Server.
struct ServerCertificatesView: View {
    /// The server, as typed or stored (`https://notes.example.com`).
    let serverURL: URL

    @State private var clientCertificate: ServerCertificates.ClientCertificateInfo?
    @State private var trustedFingerprint: String?
    @State private var presented: ServerCertificates.PresentedCertificate?
    @State private var isChecking = false
    @State private var showImporter = false
    @State private var pendingP12: Data?
    @State private var p12Password = ""
    @State private var message: String?

    private var host: String { serverURL.host()?.lowercased() ?? "" }

    var body: some View {
        List {
            Section {
                if let clientCertificate {
                    LabeledContent(String(localized: "Certificate", comment: "Client certificate row"), value: clientCertificate.subject)
                    if let expires = clientCertificate.expires {
                        LabeledContent(String(localized: "Expires", comment: "Client certificate row")) {
                            Text(expires, format: .dateTime.day().month().year())
                                .foregroundStyle(expires < .now ? Color.trinoteDestructive : Color.trinoteTextSecondary)
                        }
                    }
                    Button(String(localized: "Replace…", comment: "Client certificate action")) { showImporter = true }
                    Button(String(localized: "Remove Certificate", comment: "Client certificate action"), role: .destructive) {
                        ServerCertificates.removeClientCertificate(forHost: host)
                        reload()
                    }
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Label(String(localized: "Import Certificate (.p12)…", comment: "Client certificate action"), systemImage: "person.badge.key")
                    }
                }
            } header: {
                Text(String(localized: "Client certificate", comment: "Certificates section"))
            } footer: {
                Text(String(localized: "For servers behind a proxy that asks for a certificate (mutual TLS). Stored in the Keychain on this device only.", comment: "Client certificate footer"))
            }

            Section {
                if let trustedFingerprint {
                    fingerprintRow(trustedFingerprint)
                    Button(String(localized: "Stop Trusting", comment: "Server certificate action"), role: .destructive) {
                        ServerCertificates.removeTrust(forHost: host)
                        reload()
                    }
                } else if let presented {
                    LabeledContent(String(localized: "Issued to", comment: "Server certificate row"), value: presented.subject)
                    fingerprintRow(presented.fingerprint)
                    if presented.isTrustedBySystem {
                        Label(String(localized: "iOS already trusts this certificate.", comment: "Server certificate status"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.trinoteSyncOK)
                    } else {
                        Button {
                            do {
                                try ServerCertificates.trust(fingerprint: presented.fingerprint, forHost: host)
                                reload()
                            } catch {
                                message = error.localizedDescription
                            }
                        } label: {
                            Label(String(localized: "Trust This Certificate", comment: "Server certificate action"), systemImage: "lock.shield")
                        }
                    }
                } else {
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Label(String(localized: "Check Server Certificate", comment: "Server certificate action"), systemImage: "magnifyingglass")
                            Spacer()
                            if isChecking { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isChecking || host.isEmpty)
                }
            } header: {
                Text(String(localized: "Server certificate", comment: "Certificates section"))
            } footer: {
                Text(String(localized: "For a self-signed certificate. Compare the fingerprint with the one on your server before trusting it; if the certificate changes, the app stops connecting until you trust the new one.", comment: "Server certificate footer"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround)
        .navigationTitle(String(localized: "Certificates", comment: "Certificates screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                p12Password = ""
                pendingP12 = data
            }
        }
        .alert(
            String(localized: "Certificate Password", comment: "p12 password prompt title"),
            isPresented: Binding(get: { pendingP12 != nil }, set: { if !$0 { pendingP12 = nil } })
        ) {
            SecureField(String(localized: "Password", comment: "Login field"), text: $p12Password)
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) { pendingP12 = nil }
            Button(String(localized: "Import", comment: "p12 password prompt confirm")) { importPending() }
        } message: {
            Text(String(localized: "Enter the password the certificate file was exported with.", comment: "p12 password prompt message"))
        }
        .alert(
            String(localized: "Certificates", comment: "Certificates screen title"),
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(message ?? "") }
        )
    }

    private func fingerprintRow(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "SHA-256 fingerprint", comment: "Server certificate row"))
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextSecondary)
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func reload() {
        clientCertificate = ServerCertificates.clientCertificate(forHost: host)
        trustedFingerprint = ServerCertificates.trustedFingerprint(forHost: host)
        if trustedFingerprint != nil { presented = nil }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            presented = try await ServerCertificates.fetchPresentedCertificate(from: serverURL)
        } catch {
            message = String(localized: "The server could not be reached over HTTPS.", comment: "Server certificate check failed")
        }
    }

    private func importPending() {
        guard let data = pendingP12 else { return }
        pendingP12 = nil
        do {
            try ServerCertificates.importClientCertificate(p12: data, password: p12Password, forHost: host)
            p12Password = ""
            reload()
        } catch {
            p12Password = ""
            message = error.localizedDescription
        }
    }
}
