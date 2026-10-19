import SwiftUI

/// Settings › Quick capture saves to: the destination Quick capture starts with.
struct QuickCaptureDestinationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var chosen: CaptureDestination?
    @State private var recent: [CaptureDestination] = []
    @State private var showsPicker = false

    var body: some View {
        List {
            Section {
                row(String(localized: "Inbox", comment: "Favorites: fixed entry for Trilium's inbox"), systemImage: "tray", isOn: chosen == nil) {
                    choose(nil)
                }
                ForEach(recent, id: \.self) { destination in
                    row(destination.title, systemImage: "doc", isOn: chosen == destination) {
                        choose(destination)
                    }
                }
            } footer: {
                Text(String(localized: "Inbox is the note labeled #inbox, or a top-level note named Inbox. Without one, notes go to today's journal note.", comment: "Quick capture destination footer"))
            }
            .listRowBackground(Color.trinoteCard)

            Section {
                Button(String(localized: "Choose a note…", comment: "Quick capture destination: pick any note")) {
                    showsPicker = true
                }
            }
            .listRowBackground(Color.trinoteCard)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.trinoteGround)
        .navigationTitle(String(localized: "Quick capture saves to", comment: "Settings row"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $showsPicker) {
            ParentPickerSheet(
                navigationTitle: String(localized: "Save to", comment: "Quick capture: destination section"),
                instruction: String(localized: "Choose where Quick capture saves new notes.", comment: "Quick capture destination picker instruction"),
                topLevelButtonTitle: String(localized: "Top level (under Notes)", comment: "Move note under root"),
                onPick: { noteId, title, _ in
                    let picked = CaptureDestination(noteId: noteId, title: title)
                    if !recent.contains(picked) { recent.insert(picked, at: 0) }
                    choose(picked)
                    showsPicker = false
                }
            )
            .environment(appState)
        }
    }

    private func row(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.trinoteTextPrimary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func load() {
        guard let profileId = appState.activeProfile?.id else { return }
        chosen = CaptureDestinations.defaultDestination(profileId: profileId)
        recent = CaptureDestinations.recent(profileId: profileId)
        if let chosen, !recent.contains(chosen) { recent.insert(chosen, at: 0) }
    }

    private func choose(_ destination: CaptureDestination?) {
        guard let profileId = appState.activeProfile?.id else { return }
        chosen = destination
        CaptureDestinations.setDefaultDestination(destination, profileId: profileId)
    }
}
