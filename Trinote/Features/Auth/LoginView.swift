import SwiftUI
import UIKit

// MARK: - Shared login form (main screen + Add Instance sheet)

private enum LoginFormField: Hashable {
    case displayName
    case serverURL
    case password
    case cloudflareClientId
    case cloudflareClientSecret
}

/// Header, server URL, password, Connect button, errors, and TOTP — shared by `LoginView` and `AddInstanceView`.
struct LoginFormContent: View {
    @Bindable var viewModel: AuthViewModel
    let appState: AppState
    /// When `true` (Add Instance sheet), block login if the URL matches an existing `ServerProfile`.
    var rejectIfServerAlreadyAdded: Bool = false
    var showsWelcomeHeader: Bool = true
    /// The sign-in screen offers taking notes on this device without a server.
    var showsLocalStart: Bool = false
    /// Shown between the server and the password (servers from the person's other devices), so
    /// picking one is right where its address goes (TestFlight feedback).
    var betweenServerAndPassword: AnyView? = nil
    @State private var isPasswordVisible = false
    @State private var localStartError: String?
    @State private var confirmLocalStart = false
    @State private var showAdvanced = false
    @State private var showCertificates = false
    @FocusState private var focusedField: LoginFormField?

    var body: some View {
        VStack(spacing: 22) {
            if showsWelcomeHeader {
                header
            }
            serverForm
            if let betweenServerAndPassword { betweenServerAndPassword }
            credentialForm
            advancedForm
            actionButtons
        }
        .foregroundStyle(Color.trinoteTextPrimary)
        .alert(String(localized: "Error", comment: "Login error"), isPresented: $viewModel.showError) {
            Button(String(localized: "OK", comment: "Dismiss alert")) { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? String(localized: "An unknown error occurred.", comment: "Generic error"))
        }
        .fullScreenCover(isPresented: ssoFlowPresented) {
            SSOFlowCover(viewModel: viewModel, appState: appState)
        }
        .sheet(isPresented: $viewModel.showTotpEntry) {
            TotpEntrySheet(viewModel: viewModel, appState: appState)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done", comment: "Dismiss keyboard")) {
                    focusedField = nil
                }
            }
        }
    }

    private var ssoFlowPresented: Binding<Bool> {
        Binding(
            get: { viewModel.ssoFlowPresentation != nil },
            set: { presented in
                if !presented {
                    viewModel.cancelSSOLogin()
                }
            }
        )
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("BootstrapAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(.rect(cornerRadius: 18))
                .accessibilityHidden(true)
            Text(String(localized: "Welcome to Triquid Notes", comment: "Login welcome title"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.trinoteTextPrimary)
                .multilineTextAlignment(.center)
            Text(String(localized: "Your Trilium notes on iPhone and iPad, also offline. Connect to your Trilium server to get started.", comment: "Login welcome message"))
                .font(.system(size: 15))
                .foregroundStyle(Color.trinoteTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private func sectionCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.trinoteTextSecondary)
            .padding(.leading, 16)
    }

    /// A grouped card like Settings: rows separated by hairlines on the card color.
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
    }

    private var rowDivider: some View {
        Divider().overlay(Color.trinoteSeparator).padding(.leading, 16)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.trinoteTextSecondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionCaption(String(localized: "Server", comment: "Login section"))
            card {
                HStack(spacing: 4) {
                    Menu {
                        Picker(String(localized: "Scheme", comment: "URL scheme picker"), selection: $viewModel.urlScheme) {
                            ForEach(AuthViewModel.URLScheme.allCases, id: \.self) { scheme in
                                Text(scheme.rawValue).tag(scheme)
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(viewModel.urlScheme.rawValue)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .fixedSize()
                        .foregroundStyle(.tint)
                    }
                    .accessibilityLabel(String(localized: "Scheme", comment: "URL scheme picker"))

                    TextField(String(localized: "trilium.example.com", comment: "Login server URL placeholder"), text: $viewModel.serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .serverURL)
                        .onChange(of: viewModel.serverURL) { viewModel.absorbTypedScheme() }
                        .accessibilityLabel(String(localized: "Server URL", comment: "VoiceOver"))
                }
                .formRow()
                rowDivider
                TextField(String(localized: "Display name (optional)", comment: "Server field"), text: $viewModel.serverName)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .displayName)
                    .accessibilityLabel(String(localized: "Server display name", comment: "VoiceOver"))
                    .formRow()
            }
            footnote(String(localized: "e.g. trilium.example.com or 192.168.1.100:8080", comment: "URL hint"))
        }
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionCaption(String(localized: "Sign in", comment: "Login section"))
            card {
                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField(String(localized: "Password", comment: "Login field"), text: $viewModel.password)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .password)
                        } else {
                            SecureField(String(localized: "Password", comment: "Login field"), text: $viewModel.password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                        }
                    }
                    .accessibilityLabel(String(localized: "Server password", comment: "VoiceOver"))

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(Color.trinoteTextSecondary)
                            .accessibilityLabel(isPasswordVisible ? String(localized: "Hide password", comment: "VoiceOver") : String(localized: "Reveal password", comment: "VoiceOver"))
                    }
                    .buttonStyle(.plain)
                }
                .formRow()
                rowDivider
                Toggle(String(localized: "Stay signed in", comment: "Login toggle"), isOn: $viewModel.rememberMe)
                    .formRow()
            }
            footnote(String(localized: "The same password as the Trilium web app. Two-factor codes (TOTP) are supported.", comment: "Login hint"))
        }
    }

    /// The typed server as an HTTPS URL, for the certificates screen.
    private var certificateServerURL: URL? {
        guard let url = URL(string: ServerProfile.normalizedBaseURL(viewModel.serverURL)),
              url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            card {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 0) {
                        rowDivider.padding(.leading, -16)
                        TextField(
                            String(localized: "Cloudflare Access Client ID", comment: "Cloudflare Access field; header CF-Access-Client-Id"),
                            text: $viewModel.cloudflareClientId
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .cloudflareClientId)
                        .accessibilityLabel(String(localized: "Cloudflare Access Client ID", comment: "VoiceOver"))
                        .frame(minHeight: 46)
                        rowDivider.padding(.leading, -16)
                        SecureField(
                            String(localized: "Cloudflare Access Client Secret", comment: "Cloudflare Access field; header CF-Access-Client-Secret"),
                            text: $viewModel.cloudflareClientSecret
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .cloudflareClientSecret)
                        .accessibilityLabel(String(localized: "Cloudflare Access Client Secret", comment: "VoiceOver"))
                        .frame(minHeight: 46)
                        rowDivider.padding(.leading, -16)
                        Button {
                            focusedField = nil
                            showCertificates = true
                        } label: {
                            HStack {
                                Text(String(localized: "Certificates", comment: "Certificates screen title"))
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.trinoteTextTertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(certificateServerURL == nil)
                        .frame(minHeight: 46)
                    }
                } label: {
                    Text(String(localized: "Advanced", comment: "Login advanced section"))
                        .foregroundStyle(Color.trinoteTextPrimary)
                }
                .formRow()
            }
            if showAdvanced {
                footnote(String(localized: "Optional. Required only if your Trilium server is behind Cloudflare Access / Zero Trust, asks for a client certificate, or uses a self-signed certificate.", comment: "Cloudflare Access hint"))
            }
        }
        .sheet(isPresented: $showCertificates) {
            if let url = certificateServerURL {
                NavigationStack {
                    ServerCertificatesView(serverURL: url)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done", comment: "Dismiss sheet")) { showCertificates = false }
                            }
                        }
                }
            }
        }
    }

    /// Notes on this device only (the same as the welcome screen's choice), for later on a server.
    private var localStartButton: some View {
        VStack(spacing: 6) {
            Button {
                focusedField = nil
                // With a server already set up, say first that it stays (it is only switched away from).
                if ((try? PersistenceManager.shared.fetchServerProfiles()) ?? []).contains(where: { !$0.isLocal }) {
                    confirmLocalStart = true
                } else {
                    startLocal()
                }
            } label: {
                Label(String(localized: "Start without a server", comment: "Sign-in: take notes on this device only"), systemImage: "iphone")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            footnote(String(localized: "Notes stay on this device. Connect them to a Trilium server later in Settings.", comment: "Sign-in: local notebook hint"))
        }
        .padding(.top, 6)
        .confirmationDialog(
            String(localized: "Switch to notes on this device?", comment: "Settings: confirm switching to the local notebook"),
            isPresented: $confirmLocalStart,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Switch", comment: "Settings: confirm switching to the local notebook")) { startLocal() }
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your saved servers and their notes stay on this device; nothing is deleted. Switch back from Settings or under Instances.", comment: "Sign-in: what starting the local notebook does when servers are saved"))
        }
        .alert(
            String(localized: "Could Not Start", comment: "Local notebook start error title"),
            isPresented: Binding(get: { localStartError != nil }, set: { if !$0 { localStartError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(localStartError ?? "") }
        )
    }

    private func startLocal() {
        do {
            try appState.startLocalNotebook()
        } catch {
            localStartError = error.localizedDescription
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                focusedField = nil
                Task { await viewModel.login(appState: appState, rejectIfServerAlreadyAdded: rejectIfServerAlreadyAdded) }
            } label: {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Text(String(localized: "Connect", comment: "Login button"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.trinoteOnAccent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(!viewModel.canSubmit || viewModel.isLoading)
            .accessibilityLabel(String(localized: "Connect to server", comment: "VoiceOver"))

            Button {
                focusedField = nil
                viewModel.beginSSOLogin(appState: appState, rejectIfServerAlreadyAdded: rejectIfServerAlreadyAdded)
            } label: {
                Label(String(localized: "Sign in with SSO", comment: "SSO login button"), systemImage: "person.badge.key")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(!viewModel.canSubmitSSO || viewModel.isLoading)
            .accessibilityLabel(String(localized: "Sign in with SSO", comment: "VoiceOver"))

            footnote(String(localized: "SSO opens Safari for Authelia, Authentik, Keycloak and other providers (Face ID and security keys work). After your notes load, come back here and tap Continue.", comment: "SSO login hint"))

            if showsLocalStart {
                localStartButton
            }
        }
    }
}

private extension View {
    /// One row inside a login card: 16pt sides, at least 46pt tall.
    func formRow() -> some View {
        padding(.horizontal, 16)
            .frame(minHeight: 46)
    }
}

// MARK: - SSO flow cover (setup warning → Safari waiting)

private struct SSOFlowCover: View {
    @Bindable var viewModel: AuthViewModel
    let appState: AppState

    var body: some View {
        switch viewModel.ssoFlowPresentation {
        case .setupWarning:
            SSOSetupWarningView(
                onContinue: { skipFutureWarnings in
                    viewModel.confirmSSOSetupWarning(appState: appState, skipFutureWarnings: skipFutureWarnings)
                },
                onCancel: { viewModel.cancelSSOLogin() }
            )
        case .waitingForSafari, nil:
            SSOSafariHandoffWaitingView(
                onOpenSafariAgain: { viewModel.reopenSSOSafari() },
                onCopySetupScript: {
                    UIPasteboard.general.string = TriliumSSOHandoff.handlerNoteSource
                },
                onCancel: { viewModel.cancelSSOLogin() }
            )
        }
    }
}

// MARK: - Add Instance (from Settings)

struct AddInstanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var viewModel = AuthViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LoginFormContent(viewModel: viewModel, appState: appState, rejectIfServerAlreadyAdded: true)
                    .frame(maxWidth: 560)
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.trinoteGround)
            .navigationTitle(String(localized: "Add Instance", comment: "Sheet title: sign in to another server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Dismiss add instance")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.didFinishSuccessfulLogin = false
                viewModel.loadProfiles()
            }
            .onChange(of: viewModel.didFinishSuccessfulLogin) { _, finished in
                if finished { dismiss() }
            }
        }
    }
}

// MARK: - Connect a local notebook (from Settings)

/// Signs a local notebook in to its first Trilium server; its notes then upload into a new folder.
struct ConnectLocalNotebookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var viewModel = AuthViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(String(localized: "Sign in to your Trilium server. Your notes on this device are uploaded into a new folder there; afterwards this app works with the server like any other.", comment: "Connect local notebook explanation"))
                        .font(.subheadline)
                        .foregroundStyle(Color.trinoteTextSecondary)
                        .multilineTextAlignment(.center)
                    LoginFormContent(viewModel: viewModel, appState: appState, showsWelcomeHeader: false)
                }
                .frame(maxWidth: 560)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.trinoteGround)
            .navigationTitle(String(localized: "Connect to Trilium", comment: "Sheet title: connect a local notebook to a server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .onAppear {
                viewModel.convertingLocalProfile = appState.activeProfile
            }
            .onChange(of: viewModel.didFinishSuccessfulLogin) { _, finished in
                if finished { dismiss() }
            }
            .onDisappear {
                viewModel.revertLocalConversionIfNeeded()
            }
        }
    }
}

// MARK: - Main login

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = AuthViewModel()
    /// First launch (no saved servers): the animated welcome comes before the sign-in form.
    @State private var showsOnboarding = ((try? PersistenceManager.shared.fetchServerProfiles()) ?? []).isEmpty
    @State private var startError: String?
    @State private var cloudServers = SettingsCloudSync.cloudServers()
    /// A saved server the trash button asked to remove; confirmed first, since removing it also
    /// clears its offline notes and takes it off your other devices' list (TestFlight feedback).
    @State private var profilePendingDelete: ServerProfile?

    var body: some View {
        if showsOnboarding {
            OnboardingView(
                onConnect: {
                    withAnimation(.smooth(duration: 0.45)) { showsOnboarding = false }
                },
                onStartLocal: {
                    do {
                        try appState.startLocalNotebook()
                    } catch {
                        startError = error.localizedDescription
                    }
                }
            )
            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            .alert(
                String(localized: "Could Not Start", comment: "Local notebook start error title"),
                isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } }),
                actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
                message: { Text(startError ?? "") }
            )
        } else {
            loginForm
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var loginForm: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    LoginFormContent(
                        viewModel: viewModel,
                        appState: appState,
                        showsLocalStart: true,
                        // Saved servers and those from other devices right under the server
                        // block, where picking one fills it in (TestFlight feedback).
                        betweenServerAndPassword: hasServerShortcuts ? AnyView(VStack(spacing: 22) {
                            savedProfilesList
                            cloudServersList
                        }) : nil
                    )
                }
                // A readable column on iPad instead of fields across the whole screen.
                .frame(maxWidth: 560)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.trinoteGround)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.profiles.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.smooth(duration: 0.45)) { showsOnboarding = true }
                        } label: {
                            Label(String(localized: "Back", comment: "Login: back to the welcome screen"), systemImage: "chevron.left")
                        }
                    }
                }
            }
            .onAppear {
                viewModel.loadProfiles()
                SettingsCloudSync.shared.refreshServers()
                cloudServers = SettingsCloudSync.cloudServers()
            }
            .onReceive(NotificationCenter.default.publisher(for: .trinoteCloudServersChanged)) { _ in
                cloudServers = SettingsCloudSync.cloudServers()
            }
            .confirmationDialog(
                String(localized: "Remove this server?", comment: "Login: confirm removing a saved server"),
                isPresented: Binding(get: { profilePendingDelete != nil }, set: { if !$0 { profilePendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: profilePendingDelete
            ) { profile in
                Button(String(localized: "Remove", comment: "Login: confirm removing a saved server"), role: .destructive) {
                    Task {
                        await viewModel.deleteProfile(profile, appState: appState)
                        cloudServers = SettingsCloudSync.cloudServers()
                    }
                }
                Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            } message: { profile in
                Text(String(localized: "\(profile.name) is removed from this device and from the list on your other devices. Its offline notes on this device are deleted; your notes on the server stay.", comment: "Login: what removing a saved server does"))
            }
        }
    }

    /// Servers signed in on the person's other devices (iCloud) that this device does not know yet.
    /// Saved servers or servers from other devices to show; without either, no empty block (and
    /// its spacing) sits between the server and the password.
    private var hasServerShortcuts: Bool {
        let known = Set(viewModel.profiles.map { $0.normalizedBaseURL.lowercased() })
        return !viewModel.profiles.isEmpty || cloudServers.contains { !known.contains($0.id) }
    }

    @ViewBuilder
    private var cloudServersList: some View {
        let known = Set(viewModel.profiles.map { $0.normalizedBaseURL.lowercased() })
        let servers = cloudServers.filter { !known.contains($0.id) }
        if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "From your other devices", comment: "Login section: servers shared through iCloud"))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.leading, 16)
                ForEach(servers) { server in
                    Button {
                        withAnimation { viewModel.fillFromCloudServer(server) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "icloud")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color.trinoteTextPrimary)
                                Text(server.url)
                                    .font(.caption)
                                    .foregroundStyle(Color.trinoteTextSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(String(localized: "Use", comment: "Login: fill in a server from another device"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                }
                Text(String(localized: "Your password is never shared; sign in once on this device.", comment: "Login: iCloud server list footnote"))
                    .font(.footnote)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var savedProfilesList: some View {
        if !viewModel.profiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Saved Servers", comment: "Login section"))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.leading, 16)

                ForEach(viewModel.profiles, id: \.id) { profile in
                    SavedProfileRow(
                        profile: profile,
                        isActive: profile.id == appState.activeProfile?.id,
                        onSelect: { viewModel.fillFromProfile(profile) },
                        onConnect: {
                            Task { await viewModel.connectToProfile(profile, appState: appState) }
                        },
                        onDelete: { profilePendingDelete = profile }
                    )
                }
            }
        }
    }
}

// MARK: - TOTP Entry Sheet

private struct TotpEntrySheet: View {
    @Bindable var viewModel: AuthViewModel
    let appState: AppState
    @FocusState private var isTotpFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(String(localized: "Two-Factor Authentication", comment: "TOTP sheet title"))
                        .font(.title2.bold())
                    Text(String(localized: "Enter the code from your authenticator app.", comment: "TOTP sheet subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                TextField(String(localized: "6-digit code", comment: "TOTP field"), text: $viewModel.totpCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($isTotpFocused)
                    .accessibilityLabel(String(localized: "TOTP code", comment: "VoiceOver"))
                    .onSubmit { submit() }
                    .onChange(of: viewModel.totpCode) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.count == 6, trimmed.allSatisfy(\.isNumber) {
                            submit()
                        }
                    }

                Button {
                    submit()
                } label: {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(String(localized: "Verify", comment: "TOTP submit button"))
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.totpCode.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
                .accessibilityLabel(String(localized: "Verify TOTP code", comment: "VoiceOver"))

                Text(String(localized: "You can also enter a recovery code.", comment: "TOTP recovery hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle(String(localized: "Verify Identity", comment: "TOTP nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "TOTP cancel")) {
                        viewModel.cancelTotp(appState: appState)
                    }
                }
            }
            .alert(String(localized: "Error", comment: "TOTP error"), isPresented: $viewModel.showError) {
                Button(String(localized: "OK", comment: "Dismiss alert")) { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage ?? String(localized: "An unknown error occurred.", comment: "Generic error"))
            }
            .onAppear { isTotpFocused = true }
        }
        .interactiveDismissDisabled(viewModel.isLoading)
        .presentationDetents([.medium])
    }

    private func submit() {
        guard !viewModel.isLoading else { return }
        let trimmed = viewModel.totpCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await viewModel.submitTotp(appState: appState) }
    }
}

// MARK: - Saved Profile Row

private struct SavedProfileRow: View {
    let profile: ServerProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.body.weight(.medium))
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                                .accessibilityLabel(String(localized: "Active", comment: "Server profile active"))
                        }
                    }
                    Text(profile.normalizedBaseURL)
                        .font(.caption)
                        .foregroundStyle(Color.trinoteTextSecondary)
                        .lineLimit(1)
                    if profile.authMethod == .sso {
                        Text(String(localized: "SSO", comment: "Saved server uses SSO"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Use \(profile.name) server", comment: "VoiceOver profile row"))
            .accessibilityHint(String(localized: "Fills server URL and name", comment: "VoiceOver hint"))

            Spacer()

            if !isActive {
                Button(
                    profile.authMethod == .sso
                        ? String(localized: "Sign in with SSO", comment: "Reconnect SSO profile")
                        : String(localized: "Connect", comment: "Login profile row"),
                    action: onConnect
                )
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Remove server", comment: "VoiceOver"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
        .confirmationDialog(String(localized: "Remove \(profile.name)?", comment: "Remove profile confirm"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "Remove Server", comment: "Remove profile"), role: .destructive, action: onDelete)
            Button(String(localized: "Cancel", comment: "Cancel remove profile"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will remove the server profile and sign out. Your notes on the server will not be affected.", comment: "Remove profile message"))
        }
    }
}

// MARK: - Safari SSO waiting

private struct SSOSafariHandoffWaitingView: View {
    let onOpenSafariAgain: () -> Void
    let onCopySetupScript: () -> Void
    let onCancel: () -> Void

    @State private var didCopySetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                    Text(String(localized: "Complete sign-in in Safari", comment: "SSO Safari waiting title"))
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                    Text(String(localized: "Safari should open your SSO sign-in page. Finish Face ID or your provider there. When your notes load, return here and tap Continue.", comment: "SSO Safari waiting body"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(String(localized: "Continue", comment: "SSO reopen Safari after sign-in"), action: onOpenSafariAgain)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            String(localized: "If Safari says “No handler matched”", comment: "SSO waiting troubleshooting heading"),
                            systemImage: "wrench.and.screwdriver"
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(String(localized: "The JS Backend handler is missing on Trilium. Create that note, add the label below, paste the script, then tap Continue.", comment: "SSO waiting troubleshooting body"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("#customRequestHandler=trinote-sso-handoff")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Button {
                            onCopySetupScript()
                            didCopySetup = true
                        } label: {
                            Text(didCopySetup
                                 ? String(localized: "Copied handler script", comment: "SSO setup copied")
                                 : String(localized: "Copy handler script", comment: "SSO copy setup"))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle(String(localized: "Sign in with SSO", comment: "SSO sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "SSO cancel"), action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

#Preview("Login") {
    LoginView()
        .environment(AppState())
}

#Preview("Add Instance") {
    AddInstanceView()
        .environment(AppState())
}
