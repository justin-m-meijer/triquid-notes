import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.device.rawValue
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightIndexing = true
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage(AppDelegate.lockPortraitOrientationKey) private var lockPortraitOrientation = false
    @AppStorage("useCustomTextColor") private var useCustomTextColor: Bool = false
    @AppStorage("customLightTextColor") private var customLightTextColor: String = "#1c1c1e"
    @AppStorage("customDarkTextColor") private var customDarkTextColor: String = "#aaaaaa"

    @AppStorage("useCustomTreeColors") private var useCustomTreeColors: Bool = false
    @AppStorage("useTriliumNoteColors") private var useTriliumNoteColors: Bool = true
    @AppStorage("treeLightTextColor") private var treeLightTextColor: String = "#1c1c1e"
    @AppStorage("treeDarkTextColor") private var treeDarkTextColor: String = "#e5e5e7"
    @AppStorage("treeLightBgColor") private var treeLightBgColor: String = "#ffffff"
    @AppStorage("treeDarkBgColor") private var treeDarkBgColor: String = "#1c1c1e"
    /// Approx. system blue at 12% over white (matches prior accent wash).
    @AppStorage("treeLightSelectedNoteColor") private var treeLightSelectedNoteColor: String = "#E0EFFF"
    /// Approx. system blue at 12% over `#1c1c1e` (matches prior accent wash).
    @AppStorage("treeDarkSelectedNoteColor") private var treeDarkSelectedNoteColor: String = "#192739"

    @AppStorage("noteEditorLongPressToEdit") private var noteEditorLongPressToEdit: Bool = false
    @AppStorage("noteCheckboxReorderEnabled") private var noteCheckboxReorderEnabled: Bool = true
    /// When true, Image–Code insert tools sit in a top bar below the nav header instead of the bottom formatting toolbar.
    @AppStorage("noteEditorInsertToolsAtTop") private var noteEditorInsertToolsAtTop: Bool = false
    @AppStorage(NoteEditorSaving.autosaveKey) private var noteEditorAutosave = false
    @AppStorage(NoteEditorSaving.autosaveDelayKey) private var noteEditorAutosaveDelay = NoteEditorSaving.defaultAutosaveDelay
    @AppStorage(NoteEditorSaving.hideSaveButtonKey) private var noteEditorHideSaveButton = false
    @AppStorage(NoteEditorSaving.backButtonSavesKey) private var noteEditorBackButtonSaves = false
    @AppStorage("showNoteTabsBar") private var showNoteTabsBar: Bool = false
    @AppStorage(NoteContentWidth.storageKey) private var noteMaxContentWidth: Int = 0
    /// The iPad split layout's own tab strip setting (see `NoteDetailView.showNoteTabsBar`).
    /// Set when Settings is opened from the iPad split layout.
    @AppStorage("highlightCurrentNoteInTree") private var highlightCurrentNoteInTree: Bool = true
    @AppStorage(SSOLoginPreferences.showSetupWarningKey) private var showSSOSetupWarning = true
    @State private var showClearCacheConfirm = false
    @State private var showClearAllInstancesCacheConfirm = false
    @State private var showResetColorsConfirm = false
    @State private var showResetTreeColorsConfirm = false
    @State private var appInfo: AppInfoResponse?
    @State private var isLoadingInfo = false
    @State private var cacheEntityCount = 0
    @State private var cacheSizeBytes: Int?
    @State private var syncStatuses: [SyncStatus] = []
    @State private var showSyncDetails = false
    @AppStorage("appPinEnabled") private var appPinEnabled = false
    @AppStorage("appBiometricEnabled") private var appBiometricEnabled = false
    @State private var showPinSetup = false
    @State private var deviceBiometryKind: BiometricKind = .none
    @State private var serverProfiles: [ServerProfile] = []
    @State private var showAddInstance = false
    @State private var showConnectLocalNotebook = false
    @State private var confirmLocalNotebook = false
    @State private var backToServerError: String?
    @State private var isSwitchingBack = false
    @Environment(\.settingsPagesByValue) private var settingsPagesByValue
    @State private var profileIdPendingSignOut: String?
    @State private var cacheSizeBytesAllInstances: Int?
    @State private var activeProfileHasCloudflareAccess = false
    @AppStorage(AppState.syncOnLaunchKey) private var syncOnLaunch = true
    @AppStorage(SettingsCloudSync.enabledKey) private var syncSettingsWithICloud = true
    @State private var showSyncDetailsSheet = false
    @State private var showRenameProfile = false
    @State private var renameText = ""
    @State private var showDisconnectConfirm = false
    @State private var showCloudflareAccessSettings = false
    /// The active server's offline-cache choices; saved as they change.
    @State private var offlineCacheSettings = OfflineCacheSettings()
    @State private var showRemoveMediaConfirm = false

    var body: some View {
        List {
            Group {
            // Status card (redesign screen 4): connection, host, last sync, Sync now.
            Section {
                if appState.activeProfile?.isLocal == true {
                    localNotebookCard
                } else {
                    statusCard
                }
            }
            // Used most, so right under the status card.
            Section {
                settingsLink(SettingsPage.quickCapture) {
                    LabeledContent(String(localized: "Quick capture saves to", comment: "Settings row"), value: quickCaptureDestinationTitle)
                }
                settingsLink(SettingsPage.appearance) {
                    LabeledContent(String(localized: "Theme & accent", comment: "Appearance settings screen title"), value: accentBinding.wrappedValue.localizedTitle)
                }
                settingsLink(SettingsPage.treeEditor) {
                    Text(String(localized: "Tree & Editor", comment: "Settings page"))
                }
                // The home screen only shows beside the menu (iPad, Mac, the unfolded Duo).
                if settingsPagesByValue {
                    settingsLink(SettingsPage.homeScreen) {
                        Text(String(localized: "Home Screen", comment: "Settings page: what the home screen shows"))
                    }
                }
            } header: {
                settingsHeader(String(localized: "Personalize", comment: "Settings section: theme, tree, editor and Quick capture preferences"))
            }
            if appState.activeProfile?.isLocal != true {
            Section {
                serverRows
            } header: {
                settingsHeader(String(localized: "Server", comment: "Settings section"))
            }
            Section {
                localNotebookRow
            } footer: {
                Text(String(localized: "Notes you take there stay on this device, apart from your server. You can move them to a Trilium server later; switch back under Instances.", comment: "Settings: local notebook footer"))
            }
            }
            Section {
                Toggle(String(localized: "Sync on launch", comment: "Settings: sync automatically when the app starts"), isOn: $syncOnLaunch)
                Toggle(String(localized: "Sync settings, servers & recents with iCloud", comment: "Settings: keep preferences, the server list and recently opened notes the same on all devices"), isOn: $syncSettingsWithICloud)
                Toggle(isOn: $spotlightIndexing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Show notes in Spotlight", comment: "Settings: index cached notes in system search"))
                        Text(String(localized: "Notes saved on this device appear in system search, and offline search finds similar wording. Protected notes are never included; with the app lock on, only titles are.", comment: "Settings: Spotlight indexing footer"))
                            .font(.footnote)
                            .foregroundStyle(Color.trinoteTextSecondary)
                    }
                }
                .onChange(of: spotlightIndexing) { _, enabled in
                    let container = PersistenceManager.shared.container
                    let profile = appState.activeProfile.map { ($0.id, $0.name) }
                    Task.detached(priority: .utility) {
                        let indexer = SpotlightIndexer(modelContainer: container)
                        if enabled, let profile {
                            await indexer.update(profileId: profile.0, profileName: profile.1)
                        } else if !enabled {
                            await indexer.removeAll()
                        }
                    }
                }
                settingsLink(SettingsPage.cacheExcluded) {
                    Text(String(localized: "Keep notes offline", comment: "Settings: choose which notebooks are cached on the device"))
                }
                .disabled(appState.activeProfile == nil)
                settingsLink(SettingsPage.storage) {
                    Text(String(localized: "Storage & Sync", comment: "Settings page"))
                }
            } header: {
                settingsHeader(String(localized: "Sync", comment: "Settings section"))
            }
            Section {
                settingsLink(SettingsPage.security) {
                    LabeledContent(String(localized: "Security", comment: "Settings section"), value: securitySummary)
                }
                settingsLink(SettingsPage.instances) {
                    LabeledContent(String(localized: "Instances", comment: "Settings section: multiple servers"), value: "\(serverProfiles.count)")
                }
                settingsLink(SettingsPage.about) {
                    LabeledContent(String(localized: "About", comment: "Settings page"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            } header: {
                settingsHeader(String(localized: "Account", comment: "Settings section"))
            }
            // Destructive, in its own group (redesign screen 4).
            if let profile = appState.activeProfile, !profile.isLocal {
                Section {
                    Button(String(localized: "Disconnect server", comment: "Settings: sign out of the current server"), role: .destructive) {
                        showDisconnectConfirm = true
                    }
                    .foregroundStyle(Color.trinoteDestructive)
                }
            }
            }
            .listRowBackground(Color.trinoteCard)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround)
        .foregroundStyle(Color.trinoteTextPrimary)
        .environment(\.defaultMinListRowHeight, 46)
        .navigationTitle(String(localized: "Settings", comment: "Settings screen title"))
        .modifier(SettingsPageDestinations(enabled: settingsPagesByValue) { settingsDestination($0) })
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSyncDetailsSheet) {
            SyncDetailsView()
                .environment(appState)
                .presentationDetents([.medium, .large])
        }
        .alert(String(localized: "Display Name", comment: "Settings: rename server prompt"), isPresented: $showRenameProfile) {
            TextField(String(localized: "Display name", comment: "Settings row"), text: $renameText)
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Save", comment: "Save title")) { renameActiveProfile() }
        }
        .confirmationDialog(
            String(localized: "Disconnect server?", comment: "Settings: confirm sign out of current server"),
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Disconnect", comment: "Settings: confirm disconnect"), role: .destructive) {
                if let profile = appState.activeProfile {
                    Task { await signOutInstance(profile) }
                }
            }
        } message: {
            Text(String(localized: "This signs out and removes this server's cached notes and saved session from this device. Data on the server is not deleted.", comment: "Settings: disconnect message"))
        }
        .task { await loadDiagnostics() }
        .sheet(isPresented: $showPinSetup) {
            PinSetupSheet(isCurrentlyEnabled: appPinEnabled) {}
        }
        .sheet(isPresented: $showAddInstance) {
            AddInstanceView()
                .environment(appState)
        }
        .sheet(isPresented: $showCloudflareAccessSettings) {
            if let profile = appState.activeProfile {
                CloudflareAccessSettingsView(profile: profile)
                    .environment(appState)
            }
        }
        .onAppear {
            deviceBiometryKind = BiometricAuthenticator.availability().kind
            loadOfflineCacheSettings()
            reloadServerProfiles()
            Task { await refreshCloudflareAccessVisibility() }
        }
        .onChange(of: appState.activeProfile?.id) { _, _ in
            loadOfflineCacheSettings()
            reloadServerProfiles()
            Task {
                await loadDiagnostics()
                await refreshCloudflareAccessVisibility()
            }
        }
        .onChange(of: showAddInstance) { _, isPresented in
            if !isPresented { reloadServerProfiles() }
        }
        .onChange(of: showCloudflareAccessSettings) { _, isPresented in
            if !isPresented {
                Task { await refreshCloudflareAccessVisibility() }
            }
        }
    }

    // MARK: - Redesigned main page

    private func settingsHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.trinoteTextSecondary)
    }

    /// A subpage with the same grouped look as the main page.
    /// A row that opens a Settings page. iPad and Mac push it by value onto Settings' own stack in the
    /// note column; a phone pushes the page view itself (its stack only takes its own screens).
    @ViewBuilder
    private func settingsLink<Label: View>(_ page: SettingsPage, @ViewBuilder label: () -> Label) -> some View {
        if settingsPagesByValue {
            NavigationLink(value: page, label: label)
        } else {
            NavigationLink { settingsDestination(page) } label: { label() }
        }
    }

    /// Settings pages are pushed by value: view-destination links inside the split view's note
    /// column landed on a stack outside Settings and stayed on top of a note opened afterwards.
    private func settingsDestination(_ page: SettingsPage) -> AnyView {
        // Erased: pages hold links to further pages, so the type would contain itself.
        AnyView(settingsDestinationContent(page))
    }

    @ViewBuilder
    private func settingsDestinationContent(_ page: SettingsPage) -> some View {
        switch page {
        case .quickCapture:
                    QuickCaptureDestinationSettingsView()
                        .environment(appState)
                
        case .appearance:
                    AppearanceSettingsView()
                
        case .treeEditor:
                    settingsPage(String(localized: "Tree & Editor", comment: "Settings page")) {
                        treeViewSection
                        noteEditorSection
                        appearanceSection
                    }
                
        case .homeScreen:
                    HomeScreenSettingsView()

        case .cacheExcluded:
                    CacheExcludedRootNotesView()
                        .environment(appState)
                
        case .storage:
                    settingsPage(String(localized: "Storage & Sync", comment: "Settings page")) {
                        offlineCacheSection
                        cacheSection
                    }
                
        case .security:
                    settingsPage(String(localized: "Security", comment: "Settings section")) { securitySection }
                
        case .instances:
                    settingsPage(String(localized: "Instances", comment: "Settings section: multiple servers")) {
                        instancesSection
                        ssoSection
                    }
                
        case .about:
                    settingsPage(String(localized: "About", comment: "Settings page")) {
                        aboutIntroSection
                        connectionSection
                        aboutSection
                    }
                
        case .certificates(let url):
                    ServerCertificatesView(serverURL: url)
                
        }
    }

    private func settingsPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        List {
            content()
                .listRowBackground(Color.trinoteCard)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A local notebook: notes stay on the device until a Trilium server is connected.
    private var localNotebookCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.tint.opacity(0.14), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.activeProfile?.name ?? "")
                        .font(.headline)
                        .foregroundStyle(Color.trinoteTextPrimary)
                    Text(String(localized: "Notes are stored on this device only.", comment: "Settings: local notebook status"))
                        .font(.footnote)
                        .foregroundStyle(Color.trinoteTextSecondary)
                }
            }
            if let server = serverProfiles.first(where: { !$0.isLocal }) {
                Button {
                    isSwitchingBack = true
                    Task {
                        defer { isSwitchingBack = false }
                        do {
                            try await appState.activateProfile(server)
                        } catch {
                            let apiError = APIError.from(error)
                            if apiError.isAuthError {
                                // The saved session ran out: sign in again from the sign-in screen,
                                // which lists the saved server (this failed silently before).
                                appState.isAuthenticated = false
                            } else {
                                backToServerError = apiError.localizedDescription
                            }
                        }
                    }
                } label: {
                    // Reaching the server can take a while (a slow or unreachable one times out).
                    HStack(spacing: 8) {
                        if isSwitchingBack { ProgressView() }
                        Label(String(localized: "Back to \(server.name)", comment: "Settings: leave the local notebook for the saved server; argument is its name"), systemImage: "arrow.uturn.backward")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glass)
                .disabled(isSwitchingBack)
            }
            Button {
                showConnectLocalNotebook = true
            } label: {
                Label(String(localized: "Connect to a Trilium server", comment: "Settings: move a local notebook to a server"), systemImage: "arrow.up.to.line.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.trinoteOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.glassProminent)
            Text(String(localized: "Your notes are uploaded into a new folder on the server, next to what is already there. Nothing on the server is changed or overwritten.", comment: "Settings: what connecting a local notebook does"))
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextSecondary)
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showConnectLocalNotebook) {
            ConnectLocalNotebookView()
                .environment(appState)
        }
        .alert(
            String(localized: "Could Not Switch", comment: "Settings: switching back to the server failed"),
            isPresented: Binding(get: { backToServerError != nil }, set: { if !$0 { backToServerError = nil } }),
            actions: { Button(String(localized: "OK", comment: "Dismiss"), role: .cancel) {} },
            message: { Text(backToServerError ?? "") }
        )
    }

    /// Switches to the notes kept on this device without a server (made the first time).
    private var localNotebookRow: some View {
        let existing = serverProfiles.first(where: \.isLocal)
        return Button {
            confirmLocalNotebook = true
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing.map { String(localized: "Open \($0.name)", comment: "Settings: switch to the local notebook; argument is its name, e.g. On this iPhone") }
                         ?? String(localized: "Start without a server", comment: "Sign-in: take notes on this device only"))
                        .foregroundStyle(.tint)
                    Text(String(localized: "Notes on this device only", comment: "Settings: local notebook row subtitle"))
                        .font(.footnote)
                        .foregroundStyle(Color.trinoteTextSecondary)
                }
            } icon: {
                Image(systemName: "iphone")
            }
        }
        .confirmationDialog(
            String(localized: "Switch to notes on this device?", comment: "Settings: confirm switching to the local notebook"),
            isPresented: $confirmLocalNotebook,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Switch", comment: "Settings: confirm switching to the local notebook")) {
                do {
                    try appState.startLocalNotebook()
                } catch {
                    appState.connectionError = error.localizedDescription
                }
            }
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
        } message: {
            Text(String(localized: "\(appState.activeProfile?.name ?? "Your server") and its notes stay on this device; nothing is deleted. Switch back from the card at the top of Settings or under Instances.", comment: "Settings: what switching to the local notebook does; argument is the server's name"))
        }
    }

    private var statusCard: some View {
        let status = SyncStatusSummary(appState: appState)
        let host = appState.activeProfile.flatMap { URL(string: $0.baseURL)?.host() } ?? "–"
        let connection: (String, Color) = {
            if !appState.isOnline { return (String(localized: "Offline", comment: "Network status"), .trinoteTextTertiary) }
            if appState.connectionError != nil { return (String(localized: "Not connected", comment: "Settings status card"), .trinoteDestructive) }
            return (String(localized: "Connected", comment: "Server OK"), .trinoteSyncOK)
        }()
        return HStack(spacing: 12) {
            Button { showSyncDetailsSheet = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(.tint.opacity(0.14), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(connection.1).frame(width: 8, height: 8)
                            Text(connection.0).font(.headline).foregroundStyle(Color.trinoteTextPrimary)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("\(host) · \(status.summary.lowercased())")
                                .font(.footnote)
                                .foregroundStyle(Color.trinoteTextSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button(String(localized: "Sync now", comment: "Sync bar button")) {
                Task { await SyncStatusSummary.syncNow(appState: appState) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.tint.opacity(0.14), in: .capsule)
            .buttonStyle(.plain)
            .disabled(!status.canSyncNow)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var serverRows: some View {
        if let profile = appState.activeProfile {
            Button {
                renameText = profile.name
                showRenameProfile = true
            } label: {
                LabeledContent(String(localized: "Display name", comment: "Settings row"), value: profile.name)
                    .foregroundStyle(Color.trinoteTextPrimary)
            }
            LabeledContent(String(localized: "Server URL", comment: "Login field"), value: profile.normalizedBaseURL)
            // The app signs in with a Trilium session, not an ETAPI token (see docs/redesign-status.md).
            LabeledContent(
                String(localized: "Sign-in", comment: "Settings row: how this server is signed in"),
                value: profile.authMethod == .sso
                    ? String(localized: "SSO", comment: "Settings section")
                    : String(localized: "Password", comment: "Login field")
            )
            if let url = profile.url, url.scheme == "https" {
                settingsLink(SettingsPage.certificates(url)) {
                    Text(String(localized: "Certificates", comment: "Certificates screen title"))
                }
            }
            if activeProfileHasCloudflareAccess {
                Button(String(localized: "Cloudflare Access", comment: "Settings button to edit Cloudflare Access headers")) {
                    showCloudflareAccessSettings = true
                }
            }
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text(String(localized: "Test connection", comment: "Settings button"))
                        .foregroundStyle(.tint)
                    Spacer()
                    if isLoadingInfo { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isLoadingInfo)
        } else {
            Text(String(localized: "No instances", comment: "Settings when no server profiles"))
                .foregroundStyle(Color.trinoteTextSecondary)
        }
    }

    private var quickCaptureDestinationTitle: String {
        guard let profileId = appState.activeProfile?.id,
              let destination = CaptureDestinations.defaultDestination(profileId: profileId)
        else { return String(localized: "Inbox", comment: "Favorites: fixed entry for Trilium's inbox") }
        return destination.title
    }

    private func renameActiveProfile() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let profile = appState.activeProfile else { return }
        profile.name = name
        try? PersistenceManager.shared.saveProfile(profile)
        reloadServerProfiles()
    }


    private var appearanceSection: some View {
        Section(String(localized: "Text & Layout", comment: "Settings section")) {
            Toggle(String(localized: "Custom Text Colors", comment: "Settings"), isOn: $useCustomTextColor)

            if useCustomTextColor {
                HStack {
                    Text(String(localized: "Light Mode Text", comment: "Settings color row"))
                    Spacer()
                    ColorPicker("", selection: lightTextColorBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Dark Mode Text", comment: "Settings color row"))
                    Spacer()
                    ColorPicker("", selection: darkTextColorBinding)
                        .labelsHidden()
                }
            }

            Button(String(localized: "Reset Colors to Default…", comment: "Settings button")) {
                showResetColorsConfirm = true
            }
            .foregroundStyle(.tint)

            if AppDelegate.isPad {
                Picker(
                    String(localized: "Maximum Content Width", comment: "Settings (iPad): cap note text width for readability"),
                    selection: $noteMaxContentWidth
                ) {
                    ForEach(NoteContentWidth.options, id: \.self) { width in
                        Text(NoteContentWidth.title(for: width)).tag(width)
                    }
                }
            }

            // iPad always follows the device (multitasking needs every orientation).
            if !AppDelegate.isPad {
                Toggle(
                    String(localized: "Lock Portrait Orientation", comment: "Settings: prevent landscape rotation"),
                    isOn: $lockPortraitOrientation
                )
                .onChange(of: lockPortraitOrientation) { _, _ in
                    AppDelegate.applyUserOrientationPreference()
                }
            }
        }
        .alert(String(localized: "Reset Colors to Default?", comment: "Settings alert title"), isPresented: $showResetColorsConfirm) {
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Reset", comment: "Confirm reset colors")) {
                resetAllColorSettingsToDefaults()
            }
        } message: {
            Text(String(localized: "This restores the default accent theme, turns off custom app and tree colors, and resets every custom color to its default value.", comment: "Reset colors alert"))
        }
    }

    private var lightTextColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customLightTextColor) },
            set: { customLightTextColor = $0.hexString }
        )
    }

    private var darkTextColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customDarkTextColor) },
            set: { customDarkTextColor = $0.hexString }
        )
    }

    private var treeViewSection: some View {
        Section(String(localized: "Tree View", comment: "Settings section")) {
            Toggle(
                String(localized: "Show tab bar", comment: "Settings: show open-note tab strip at bottom of tree"),
                isOn: $showNoteTabsBar
            )

            Toggle(
                String(localized: "Highlight current note", comment: "Settings: highlight the current note row in the tree"),
                isOn: $highlightCurrentNoteInTree
            )

            Toggle(String(localized: "Use Trilium Note Colors", comment: "Settings: per-note colors from server"), isOn: $useTriliumNoteColors)

            Toggle(String(localized: "Custom Tree Colors", comment: "Settings"), isOn: $useCustomTreeColors)

            if useCustomTreeColors {
                HStack {
                    Text(String(localized: "Light Text", comment: "Tree color row"))
                    Spacer()
                    ColorPicker("", selection: treeLightTextBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Dark Text", comment: "Tree color row"))
                    Spacer()
                    ColorPicker("", selection: treeDarkTextBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Light Background", comment: "Tree color row"))
                    Spacer()
                    ColorPicker("", selection: treeLightBgBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Dark Background", comment: "Tree color row"))
                    Spacer()
                    ColorPicker("", selection: treeDarkBgBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Light Selected Note", comment: "Tree color row: highlighted note background in light mode"))
                    Spacer()
                    ColorPicker("", selection: treeLightSelectedNoteBinding)
                        .labelsHidden()
                }

                HStack {
                    Text(String(localized: "Dark Selected Note", comment: "Tree color row: highlighted note background in dark mode"))
                    Spacer()
                    ColorPicker("", selection: treeDarkSelectedNoteBinding)
                        .labelsHidden()
                }

                Button(String(localized: "Reset Colors to Default", comment: "Settings: reset custom tree colors only")) {
                    showResetTreeColorsConfirm = true
                }
                .foregroundStyle(.tint)
            }
        }
        .alert(
            String(localized: "Reset Tree Colors to Default?", comment: "Settings alert title"),
            isPresented: $showResetTreeColorsConfirm
        ) {
            Button(String(localized: "Cancel", comment: "Alert dismiss"), role: .cancel) {}
            Button(String(localized: "Reset", comment: "Confirm reset tree colors")) {
                resetCustomTreeColorsToDefaults()
            }
        } message: {
            Text(
                String(
                    localized: "This restores the default text, background, and selected-note colors for the tree. Custom Tree Colors stays on.",
                    comment: "Settings alert: reset custom tree colors"
                )
            )
        }
    }

    private var treeLightTextBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeLightTextColor) },
            set: { treeLightTextColor = $0.hexString }
        )
    }

    private var treeDarkTextBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeDarkTextColor) },
            set: { treeDarkTextColor = $0.hexString }
        )
    }

    private var treeLightBgBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeLightBgColor) },
            set: { treeLightBgColor = $0.hexString }
        )
    }

    private var treeDarkBgBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeDarkBgColor) },
            set: { treeDarkBgColor = $0.hexString }
        )
    }

    private var treeLightSelectedNoteBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeLightSelectedNoteColor) },
            set: { treeLightSelectedNoteColor = $0.hexString }
        )
    }

    private var treeDarkSelectedNoteBinding: Binding<Color> {
        Binding(
            get: { Color(hex: treeDarkSelectedNoteColor) },
            set: { treeDarkSelectedNoteColor = $0.hexString }
        )
    }

    private var noteEditorSection: some View {
        Section {
            Toggle(
                String(localized: "Long-Press to Edit", comment: "Settings toggle: replace the floating edit button with a long-press gesture"),
                isOn: $noteEditorLongPressToEdit
            )
            Toggle(
                String(localized: "Reorder List Items", comment: "Settings toggle: show drag handles to reorder bullet, numbered, and checkbox list items in read-only notes"),
                isOn: $noteCheckboxReorderEnabled
            )
            Toggle(
                String(localized: "Split Editor Toolbar", comment: "Settings toggle: move insert tools to a top toolbar above the note"),
                isOn: $noteEditorInsertToolsAtTop
            )
            Toggle(
                String(localized: "Autosave", comment: "Settings toggle: save the note a few seconds after you stop typing, without leaving the editor"),
                isOn: $noteEditorAutosave
            )
            if noteEditorAutosave {
                Picker(
                    String(localized: "Autosave After", comment: "Settings picker: seconds without typing before the note autosaves"),
                    selection: noteEditorAutosaveDelayBinding
                ) {
                    ForEach(NoteEditorSaving.autosaveDelayOptions, id: \.self) { seconds in
                        Text(NoteEditorSaving.delayTitle(for: seconds)).tag(seconds)
                    }
                }
                Toggle(
                    String(localized: "Hide Save Button", comment: "Settings toggle: hide the editor's floating save button while Autosave is on"),
                    isOn: $noteEditorHideSaveButton
                )
            }
            Toggle(
                String(localized: "Back Button Saves", comment: "Settings toggle: tapping Back while editing saves the note"),
                isOn: noteEditorBackButtonSavesBinding
            )
            // Autosave always saves on Back, so the toggle shows on until Autosave is turned off.
            .disabled(noteEditorAutosave)
        } header: {
            Text(String(localized: "Note Editor", comment: "Settings section header"))
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(
                    localized: "Long-Press to Edit hides the floating edit button. Press and hold the note for 1.5 seconds to start editing.",
                    comment: "Settings footer: Long-Press to Edit"
                ))
                Text(String(
                    localized: "Reorder List Items shows drag handles on bullet, numbered, and checkbox list rows so you can reorder them without opening the editor.",
                    comment: "Settings footer: Reorder List Items"
                ))
                Text(String(
                    localized: "Split Editor Toolbar moves insert tools (image, table, code, and similar) to a bar under the header—the same as the rightmost button on the formatting toolbar.",
                    comment: "Settings footer: Split Editor Toolbar"
                ))
                Text(String(
                    localized: "Autosave saves your changes a few seconds after you stop typing, and when you leave the note, without closing the editor.",
                    comment: "Settings footer: Autosave"
                ))
                if noteEditorAutosave {
                    Text(String(
                        localized: "Hide Save Button removes the floating save button. To close the editor, use Save in the ⋯ menu or tap Back.",
                        comment: "Settings footer: Hide Save Button"
                    ))
                }
                Text(String(
                    localized: "Back Button Saves saves the note when you tap Back while editing, instead of keeping a draft. On iPad it also saves when you open another note from the sidebar. Autosave always does this.",
                    comment: "Settings footer: Back Button Saves"
                ))
            }
        }
    }

    private var securitySummary: String {
        switch (appPinEnabled, appBiometricEnabled) {
        case (true, true): String(format: String(localized: "PIN and %@", comment: "Settings: app PIN and biometrics on; %@ is Face ID"), deviceBiometryKind.localizedShortName)
        case (true, false): String(localized: "PIN on", comment: "Settings: app PIN enabled")
        case (false, true): deviceBiometryKind.localizedShortName
        case (false, false): String(localized: "Off", comment: "PIN status")
        }
    }

    /// Shows the default for a stored delay that isn't one of the options.
    private var noteEditorAutosaveDelayBinding: Binding<Int> {
        Binding(
            get: { NoteEditorSaving.autosaveDelay(forStored: noteEditorAutosaveDelay) },
            set: { noteEditorAutosaveDelay = $0 }
        )
    }

    /// Reads as on while Autosave is on; writes only the user's own choice.
    private var noteEditorBackButtonSavesBinding: Binding<Bool> {
        Binding(
            get: { NoteEditorSaving.savesWhenLeaving(autosave: noteEditorAutosave, backButtonSaves: noteEditorBackButtonSaves) },
            set: { noteEditorBackButtonSaves = $0 }
        )
    }

    private var securitySection: some View {
        Section {
            Button {
                showPinSetup = true
            } label: {
                HStack {
                    Text(String(localized: "App PIN", comment: "Settings: app PIN lock"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(appPinEnabled
                         ? String(localized: "On", comment: "PIN status")
                         : String(localized: "Off", comment: "PIN status"))
                        .foregroundStyle(.secondary)
                }
            }

            if deviceBiometryKind != .none {
                Toggle(deviceBiometryKind.localizedUnlockToggleTitle, isOn: biometricUnlockBinding)
            }
        } header: {
            Text(String(localized: "Security", comment: "Settings section"))
        } footer: {
            if deviceBiometryKind != .none {
                Text(
                    String(
                        format: String(
                            localized: "With %@ on, the app unlocks when you open it. Without an app PIN, your device passcode is the fallback.",
                            comment: "Settings footer: %@ is Face ID, Touch ID, or Optic ID"
                        ),
                        locale: .current,
                        deviceBiometryKind.localizedShortName
                    )
                )
            }
        }
    }

    private var biometricUnlockBinding: Binding<Bool> {
        Binding(
            get: { appBiometricEnabled },
            set: { newValue in
                if !newValue {
                    appBiometricEnabled = false
                } else {
                    Task { @MainActor in
                        let reason = String(
                            localized: "Confirm to enable biometric unlock for Triquid Notes.",
                            comment: "System biometric prompt when turning on biometric unlock in Settings"
                        )
                        let result = await BiometricAuthenticator.authenticate(localizedReason: reason)
                        if case .success = result {
                            appBiometricEnabled = true
                        }
                    }
                }
            }
        )
    }

    private var instancesSection: some View {
        Section {
            if serverProfiles.isEmpty {
                Text(String(localized: "No instances", comment: "Settings when no server profiles"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(serverProfiles, id: \.id) { profile in
                    let isActive = profile.id == appState.activeProfile?.id
                    HStack(alignment: .center, spacing: 10) {
                        Button {
                            if !isActive {
                                Task {
                                    do {
                                        try await appState.activateProfile(profile)
                                    } catch {
                                        appState.connectionError = APIError.from(error).localizedDescription
                                    }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if isActive {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                            .accessibilityLabel(String(localized: "Active instance", comment: "VoiceOver: current server"))
                                    }
                                }
                                Text(profile.normalizedBaseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if isActive {
                                    Text(String(localized: "Active", comment: "Label on current instance row"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isActive)

                        Button {
                            profileIdPendingSignOut = profile.id
                        } label: {
                            Text(String(localized: "Sign Out", comment: "Per-instance sign out in settings"))
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityLabel(
                            String(
                                format: String(localized: "Sign out from %@", comment: "VoiceOver: sign out server; %@ is name"),
                                locale: .current,
                                profile.name
                            )
                        )
                    }
                }
            }

            Button {
                showAddInstance = true
            } label: {
                Label(String(localized: "Add Instance", comment: "Settings: sign in to another server"), systemImage: "plus.circle.fill")
            }
            .disabled(serverProfiles.count >= PersistenceManager.maxServerProfiles)
        } header: {
            Text(String(localized: "Instances", comment: "Settings section: multiple servers"))
        } footer: {
            if serverProfiles.count >= PersistenceManager.maxServerProfiles {
                Text(
                    String(
                        format: String(
                            localized: "You can sign in to at most %lld instances. Sign out from one to add another.",
                            comment: "Settings footer when instance limit reached; %lld is max count"
                        ),
                        locale: .current,
                        Int64(PersistenceManager.maxServerProfiles)
                    )
                )
            }
        }
        .alert(
            String(localized: "Sign Out?", comment: "Confirm sign out instance title"),
            isPresented: Binding(
                get: { profileIdPendingSignOut != nil },
                set: { if !$0 { profileIdPendingSignOut = nil } }
            )
        ) {
            Button(String(localized: "Cancel", comment: "Cancel sign out"), role: .cancel) {
                profileIdPendingSignOut = nil
            }
            Button(String(localized: "Sign Out", comment: "Confirm sign out"), role: .destructive) {
                if let id = profileIdPendingSignOut,
                   let profile = serverProfiles.first(where: { $0.id == id }) {
                    Task { await signOutInstance(profile) }
                }
                profileIdPendingSignOut = nil
            }
        } message: {
            if let id = profileIdPendingSignOut,
               let name = serverProfiles.first(where: { $0.id == id })?.name {
                Text(
                    String(
                        format: String(
                            localized: "Sign out from \"%@\"? This removes the instance, cached notes, and saved session from this device. Data on the server is not deleted.",
                            comment: "Confirm sign out instance; %@ is server display name"
                        ),
                        locale: .current,
                        name
                    )
                )
            }
        }
    }

    private var ssoSection: some View {
        Section {
            Toggle(
                String(localized: "Show SSO setup warning", comment: "Settings: show JS Backend handler reminder before SSO"),
                isOn: $showSSOSetupWarning
            )
        } header: {
            Text(String(localized: "SSO", comment: "Settings section"))
        } footer: {
            Text(
                String(
                    localized: "Before Sign in with SSO, confirm that the JS Backend handler is installed on Trilium. Turn this off after you have set it up.",
                    comment: "Settings footer for SSO setup warning"
                )
            )
        }
    }

    /// What the app is, and where Trilium itself lives.
    private var aboutIntroSection: some View {
        Section {
            VStack(spacing: 10) {
                Image("BootstrapAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(String(localized: "Triquid Notes", comment: "App name"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.trinoteTextPrimary)
                Text(String(localized: "A native iPhone, iPad and Mac app for Trilium Notes, the open-source knowledge base you host yourself. Your notes stay on your own server; the app keeps a copy on the device so you can read and write offline, and syncs when you are back online.", comment: "About page introduction"))
                    .font(.subheadline)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Link(destination: URL(string: "https://triliumnotes.org")!) {
                Label(String(localized: "Trilium Notes website", comment: "About link"), systemImage: "globe")
            }
            Link(destination: URL(string: "https://docs.triliumnotes.org")!) {
                Label(String(localized: "Trilium documentation", comment: "About link"), systemImage: "book")
            }
            Link(destination: URL(string: "https://github.com/TriliumNext/Trilium")!) {
                Label(String(localized: "Trilium on GitHub", comment: "About link"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/StephenArg/Trinote")!) {
                Label(String(localized: "Based on Trinote by StephenArg", comment: "About link: the app this one is forked from"), systemImage: "arrow.triangle.branch")
            }
        }
    }

    private var connectionSection: some View {
        Section(String(localized: "Connection", comment: "Settings section")) {
            HStack {
                Label(String(localized: "Network", comment: "Settings connection row"), systemImage: appState.isOnline ? "wifi" : "wifi.slash")
                Spacer()
                Text(
                    appState.isOnline
                        ? String(localized: "Online (\(appState.networkMonitor.connectionType.rawValue))", comment: "Network status with type")
                        : String(localized: "Offline", comment: "Network status")
                )
                    .foregroundStyle(appState.isOnline ? .green : .red)
                    .font(.callout)
            }

            HStack {
                Label(String(localized: "Server Status", comment: "Settings connection row"), systemImage: appState.connectionError == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                Spacer()
                Text(appState.connectionError == nil ? String(localized: "Connected", comment: "Server OK") : String(localized: "Error", comment: "Server error state"))
                    .foregroundStyle(appState.connectionError == nil ? .green : .red)
                    .font(.callout)
            }

            if let error = appState.connectionError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastRefreshed = appState.lastRefreshed {
                LabeledContent(String(localized: "Last Refreshed", comment: "Settings"), value: lastRefreshed.relativeDisplay)
            }

            if activeProfileHasCloudflareAccess {
                Button(String(localized: "Cloudflare Access", comment: "Settings button to edit Cloudflare Access headers")) {
                    showCloudflareAccessSettings = true
                }
            }

            Button(String(localized: "Test Connection", comment: "Settings button")) {
                Task { await testConnection() }
            }
            .disabled(isLoadingInfo)
        }
    }

    @ViewBuilder
    private var offlineCacheSection: some View {
        if appState.activeProfile != nil {
            OfflineCacheOptionSections(settings: $offlineCacheSettings)
                .onChange(of: offlineCacheSettings) { _, new in
                    guard let profileId = appState.activeProfile?.id else { return }
                    let saved = OfflineCacheSettings.load(profileId: profileId)
                    // Equal to what's saved: just loaded, nothing to write.
                    guard new != saved else { return }
                    new.save(profileId: profileId)
                    if saved.cachesMediaBodies, !new.cachesMediaBodies {
                        showRemoveMediaConfirm = true
                    }
                }
                .confirmationDialog(
                    String(localized: "Remove Downloaded Images, Videos & Files?", comment: "Offline cache: confirm dropping cached media bodies"),
                    isPresented: $showRemoveMediaConfirm,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Remove", comment: "Offline cache: drop cached media bodies"), role: .destructive) {
                        if let profileId = appState.activeProfile?.id {
                            try? PersistenceManager.shared.clearCachedMediaBodies(serverProfileId: profileId)
                            Task { await loadDiagnostics() }
                        }
                    }
                    Button(String(localized: "Keep", comment: "Offline cache: keep cached media bodies"), role: .cancel) {}
                } message: {
                    Text(
                        String(
                            localized: "They download again when you open them. Keep them to only stop new downloads.",
                            comment: "Offline cache: remove cached media message"
                        )
                    )
                }
        }
    }

    private func loadOfflineCacheSettings() {
        guard let profileId = appState.activeProfile?.id else { return }
        offlineCacheSettings = OfflineCacheSettings.load(profileId: profileId)
    }

    private var cacheSection: some View {
        Section(String(localized: "Cache & Sync", comment: "Settings section")) {
            LabeledContent(String(localized: "Cached Entities", comment: "Settings cache"), value: "\(cacheEntityCount)")

            if let bytes = cacheSizeBytes {
                LabeledContent(String(localized: "Cache Size", comment: "Settings cache"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }

            if let bytesAll = cacheSizeBytesAllInstances {
                LabeledContent(
                    String(localized: "Cache Size (all instances)", comment: "Settings cache across all signed-in servers"),
                    value: ByteCountFormatter.string(fromByteCount: Int64(bytesAll), countStyle: .file)
                )
            }

            if let lastSync = appState.syncManager.lastFullSyncDate {
                LabeledContent(String(localized: "Last Full Sync", comment: "Settings sync"), value: lastSync.relativeDisplay)
            }

            if let lastIncr = appState.syncManager.lastIncrementalSyncDate,
               lastIncr != appState.syncManager.lastFullSyncDate {
                LabeledContent(String(localized: "Last Quick Sync", comment: "Settings sync"), value: lastIncr.relativeDisplay)
            }

            if let server = appState.syncManager.serverPullProgress {
                HStack(spacing: 8) {
                    ProgressView(value: server.fraction)
                        .frame(width: 60)
                    Text(String(localized: "Server syncing \(server.pulled)/\(server.total) changes…", comment: "Settings: the server pulls from its own sync server"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if appState.syncManager.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    switch appState.syncManager.phase {
                    case .walkingTree:
                        Text(String(localized: "Discovering notes…", comment: "Sync phase"))
                    case .fetchingChanges:
                        let sm = appState.syncManager
                        if sm.totalNoteCount > 0 {
                            Text(String(localized: "Syncing \(sm.syncedNoteCount)/\(sm.totalNoteCount) changes…", comment: "Sync progress: entity changes"))
                        } else {
                            Text(String(localized: "Checking for changes…", comment: "Sync phase"))
                        }
                    case .downloadingContent:
                        let sm = appState.syncManager
                        if sm.totalNoteCount > 0 {
                            Text(String(localized: "Syncing \(sm.syncedNoteCount)/\(sm.totalNoteCount) notes…", comment: "Sync progress"))
                        } else {
                            Text(String(localized: "Downloading content…", comment: "Sync phase"))
                        }
                    case .cleaningUp:
                        Text(String(localized: "Cleaning up…", comment: "Sync phase"))
                    default:
                        Text(String(localized: "Syncing…", comment: "Sync phase"))
                    }
                }
                .font(.callout)
                .foregroundStyle(.blue)
            }

            Button {
                Task {
                    guard await appState.refreshTriliumSession() else { return }
                    await appState.runFullSync()
                }
            } label: {
                Label(String(localized: "Full Sync (All Notes)", comment: "Settings sync button"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(appState.syncManager.isSyncing || appState.client == nil)

            if appState.imageCachePrefetcher.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    let prefetch = appState.imageCachePrefetcher
                    if prefetch.totalImageRefs > 0 {
                        Text(
                            String(
                                localized: "Prefetching images \(prefetch.prefetchedCount)/\(prefetch.totalImageRefs)…",
                                comment: "Settings image cache prefetch progress"
                            )
                        )
                    } else {
                        Text(String(localized: "Scanning notes for images…", comment: "Settings image cache prefetch"))
                    }
                }
                .font(.callout)
                .foregroundStyle(.blue)
            }

            Button {
                Task {
                    guard await appState.refreshTriliumSession() else { return }
                    if let client = appState.client, let profileId = appState.activeProfile?.id {
                        appState.imageCachePrefetcher.prefetchAllInlineImages(client: client, profileId: profileId)
                    }
                }
            } label: {
                Label(String(localized: "Fetch All Images & Files", comment: "Settings button to cache inline images and attachments"), systemImage: "photo.on.rectangle.angled")
            }
            .disabled(
                appState.syncManager.isSyncing
                    || appState.imageCachePrefetcher.isRunning
                    || appState.client == nil
                    || !appState.isOnline
                    || !offlineCacheSettings.cachesMediaBodies
            )

            Text(
                String(
                    localized: "Downloads the images and files (PDFs, documents) your cached notes show or link to, so they open offline. Attachments you open are kept as well. Protected notes without cached bodies are skipped.",
                    comment: "Settings footnote for Fetch All Images"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let prefetchError = appState.imageCachePrefetcher.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(prefetchError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let error = appState.syncManager.syncError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if PersistenceManager.shared.isUsingMemoryFallback {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(String(localized: "Using in-memory fallback (data won't persist)", comment: "Settings warning"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !syncStatuses.isEmpty {
                DisclosureGroup(String(localized: "Sync Details", comment: "Settings disclosure"), isExpanded: $showSyncDetails) {
                    ForEach(syncStatuses, id: \.id) { status in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(status.domain.capitalized)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text(status.lastSyncedAt.relativeDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let error = status.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            settingsLink(SettingsPage.cacheExcluded) {
                Label(
                    String(localized: "Cached Notebooks", comment: "Settings link to cache exclusion list"),
                    systemImage: "externaldrive.badge.xmark"
                )
            }
            .disabled(appState.activeProfile == nil)

            Button(String(localized: "Clear Cache", comment: "Settings destructive"), role: .destructive) {
                showClearCacheConfirm = true
            }
            .disabled(appState.activeProfile == nil)
            .confirmationDialog(String(localized: "Clear Cache?", comment: "Settings confirm"), isPresented: $showClearCacheConfirm) {
                Button(String(localized: "Clear All Cached Data", comment: "Settings confirm"), role: .destructive) {
                    clearCache()
                }
            } message: {
                Text(String(localized: "This will remove all locally cached notes, branches, and attributes for this server. Your data on the server is not affected.", comment: "Clear cache message"))
            }

            Button(String(localized: "Clear Cache (all instances)", comment: "Settings: clear cache for every server"), role: .destructive) {
                showClearAllInstancesCacheConfirm = true
            }
            .disabled(serverProfiles.isEmpty)
            .confirmationDialog(
                String(localized: "Clear Cache (all instances)?", comment: "Confirm clear all instances cache"),
                isPresented: $showClearAllInstancesCacheConfirm
            ) {
                Button(String(localized: "Clear All Instances", comment: "Confirm clear all caches"), role: .destructive) {
                    clearCacheAllInstances()
                }
                Button(String(localized: "Cancel", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        localized: "This removes locally cached notes, branches, and attributes for every signed-in instance. Profiles and sessions stay signed in. Server data is not affected.",
                        comment: "Message for clear cache all instances"
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        if let info = appInfo {
            Section(String(localized: "Trilium Server", comment: "Settings about section")) {
                LabeledContent(String(localized: "Version", comment: "App version label"), value: info.appVersion)
                if let dbVersion = info.dbVersion {
                    LabeledContent(String(localized: "DB Version", comment: "Server info"), value: String(dbVersion))
                }
                if let syncVersion = info.syncVersion {
                    LabeledContent(String(localized: "Sync Version", comment: "Server info"), value: String(syncVersion))
                }
                if let buildDate = info.buildDate {
                    LabeledContent(String(localized: "Build Date", comment: "Server info"), value: buildDate)
                }
                serverCompatibilityRow(for: info)
            }
        }

        Section(String(localized: "App", comment: "Settings about section")) {
            LabeledContent(String(localized: "Version", comment: "App version label"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            LabeledContent(String(localized: "Build", comment: "App build number"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
        }
    }

    /// Non-blocking notice when the connected Trilium server is newer than what this build
    /// of Trinote was tested against. Pulled from `TriliumServerCompatibility`.
    @ViewBuilder
    private func serverCompatibilityRow(for info: AppInfoResponse) -> some View {
        switch TriliumServerCompatibility.evaluate(info) {
        case .withinTestedRange, .unknown:
            EmptyView()
        case .syncVersionAhead(let serverSync, let testedSync):
            CompatibilityBanner(
                title: String(localized: "Server newer than tested", comment: "Settings: server compatibility banner title"),
                message: String(
                    format: String(
                        localized: "This server's sync protocol (v%1$d) is newer than what this build of Triquid Notes (tested through Trilium %2$@, sync v%3$d) has been verified against. Incremental sync may misbehave; full-sync from Settings if you see stale data.",
                        comment: "Settings: server sync version warning. %1$d server sync, %2$@ tested Trilium tag, %3$d tested sync."
                    ),
                    serverSync,
                    TriliumServerCompatibility.testedMaxAppVersion,
                    testedSync
                )
            )
        case .dbVersionAhead(let serverDb, let testedDb):
            CompatibilityBanner(
                title: String(localized: "Server newer than tested", comment: "Settings: server compatibility banner title"),
                message: String(
                    format: String(
                        localized: "This server's database schema (v%1$d) is newer than what this build of Triquid Notes (tested through Trilium %2$@, db v%3$d) has been verified against. New note types or fields may not display correctly until Trinote is updated.",
                        comment: "Settings: server db version warning. %1$d server db, %2$@ tested Trilium tag, %3$d tested db."
                    ),
                    serverDb,
                    TriliumServerCompatibility.testedMaxAppVersion,
                    testedDb
                )
            )
        }
    }

    private func testConnection() async {
        guard appState.client != nil else { return }
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        let ok = await appState.refreshTriliumSession()
        guard ok, appState.client != nil else { return }
        // The session refresh just re-read the version; show the same one the app now uses.
        appInfo = appState.serverAppInfo
        do {
            if appInfo == nil, let client = appState.client {
                appInfo = try await client.getAppInfo()
            }
        } catch {
            appState.connectionError = APIError.from(error).localizedDescription
            Log.api.error("Failed to load app info: \(error)")
        }
    }

    private func loadDiagnostics() async {
        if appState.client != nil {
            isLoadingInfo = true
            // Also updates the version the rest of the app checks, so Settings never shows a newer one than it uses.
            await appState.refreshServerAppInfo()
            appInfo = appState.serverAppInfo
            isLoadingInfo = false
        }

        if let profileId = appState.activeProfile?.id {
            cacheEntityCount = (try? PersistenceManager.shared.estimateCacheSize(for: profileId)) ?? 0
            cacheSizeBytes = try? PersistenceManager.shared.estimateCacheSizeInBytes(for: profileId)
            syncStatuses = (try? PersistenceManager.shared.fetchSyncStatuses(serverProfileId: profileId)) ?? []
        } else {
            cacheEntityCount = 0
            cacheSizeBytes = nil
            syncStatuses = []
        }
        cacheSizeBytesAllInstances = try? PersistenceManager.shared.estimateCacheSizeInBytesAllInstances()
    }

    private func reloadServerProfiles() {
        serverProfiles = (try? PersistenceManager.shared.fetchServerProfiles()) ?? []
    }

    private func refreshCloudflareAccessVisibility() async {
        guard let profile = appState.activeProfile else {
            activeProfileHasCloudflareAccess = false
            return
        }
        activeProfileHasCloudflareAccess = await appState.hasCloudflareAccessCredentials(for: profile)
    }

    private func signOutInstance(_ profile: ServerProfile) async {
        await appState.signOutAndRemoveProfile(profile)
        reloadServerProfiles()
        await loadDiagnostics()
    }

    private func clearCacheAllInstances() {
        do {
            try PersistenceManager.shared.clearCacheAllInstances()
            cacheSizeBytesAllInstances = 0
            if let profileId = appState.activeProfile?.id {
                cacheEntityCount = (try? PersistenceManager.shared.estimateCacheSize(for: profileId)) ?? 0
                cacheSizeBytes = try? PersistenceManager.shared.estimateCacheSizeInBytes(for: profileId)
                syncStatuses = (try? PersistenceManager.shared.fetchSyncStatuses(serverProfileId: profileId)) ?? []
            } else {
                cacheEntityCount = 0
                cacheSizeBytes = nil
                syncStatuses = []
            }
        } catch {
            Log.persistence.error("Failed to clear all-instance cache: \(error)")
        }
    }

    private func clearCache() {
        guard let profileId = appState.activeProfile?.id else { return }
        do {
            try PersistenceManager.shared.clearCache(for: profileId)
            cacheEntityCount = 0
            cacheSizeBytes = 0
            syncStatuses = []
            cacheSizeBytesAllInstances = try? PersistenceManager.shared.estimateCacheSizeInBytesAllInstances()
        } catch {
            Log.persistence.error("Failed to clear cache: \(error)")
        }
    }

    /// Reads a theme chosen before the redesign until an accent is picked here.
    private var accentBinding: Binding<AppAccent> {
        Binding(
            get: { AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme) },
            set: { appAccent = $0.rawValue }
        )
    }

    /// Matches initial `@AppStorage` defaults in this view and `TreeView`.
    private func resetAllColorSettingsToDefaults() {
        colorTheme = ColorTheme.default.rawValue
        appAccent = AppAccent.default.rawValue
        useCustomTextColor = false
        customLightTextColor = "#1c1c1e"
        customDarkTextColor = "#aaaaaa"
        useCustomTreeColors = false
        useTriliumNoteColors = true
        resetCustomTreeColorsToDefaults()
    }

    /// Restores default custom tree color pickers only; leaves Custom Tree Colors enabled.
    private func resetCustomTreeColorsToDefaults() {
        treeLightTextColor = "#1c1c1e"
        treeDarkTextColor = "#e5e5e7"
        treeLightBgColor = "#ffffff"
        treeDarkBgColor = "#1c1c1e"
        treeLightSelectedNoteColor = "#E0EFFF"
        treeDarkSelectedNoteColor = "#192739"
    }
}

private struct CompatibilityBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppState())
}

/// A page under Settings, pushed by value.
enum SettingsPage: Hashable {
    case quickCapture
    case appearance
    case treeEditor
    case homeScreen
    case cacheExcluded
    case storage
    case security
    case instances
    case about
    case certificates(URL)
}

extension EnvironmentValues {
    /// Set where Settings has a path-free stack of its own (iPad and Mac note column).
    @Entry var settingsPagesByValue = false
}

private struct SettingsPageDestinations<Destination: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let destination: (SettingsPage) -> Destination

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: SettingsPage.self, destination: destination)
        } else {
            content
        }
    }
}
