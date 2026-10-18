import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoading {
                LaunchView()
            } else if appState.isAuthenticated {
                MainShellView()
            } else {
                LoginView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.3), value: appState.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: appState.isLoading)
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if authenticated {
                appState.shareImport.onAuthenticated()
            }
        }
        .onChange(of: appState.isLoading) { _, loading in
            if !loading {
                appState.shareImport.checkForPendingPayload()
                #if DEBUG
                Task { await debugLoginIfAsked() }
                #endif
            }
        }
    }

    #if DEBUG
    /// `-TrinoteDebugLoginURL http://127.0.0.1:37999 -TrinoteDebugLoginPassword … [-TrinoteDebugLoginName Home]`:
    /// sign in to a local test server at launch, for simulators whose display can't take input
    /// (the unfolded Duo) and for screenshots. Debug builds only; skipped when already on that server.
    private func debugLoginIfAsked() async {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "TrinoteDebugLoginURL"),
              let password = defaults.string(forKey: "TrinoteDebugLoginPassword") else { return }
        let target = ServerProfile(name: url, baseURL: url).normalizedBaseURL
        if appState.activeProfile?.normalizedBaseURL == target { return }
        let viewModel = AuthViewModel()
        viewModel.serverURL = url
        viewModel.password = password
        viewModel.serverName = defaults.string(forKey: "TrinoteDebugLoginName") ?? ""
        await viewModel.login(appState: appState)
    }
    #endif
}
