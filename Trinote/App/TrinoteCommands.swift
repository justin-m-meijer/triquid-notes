import SwiftUI

/// What the main window can do from the keyboard, published by `MainShellView`.
struct MainWindowActions {
    var show: (SidebarItem) -> Void
    var newNote: () -> Void
    var syncNow: () -> Void
}

/// What the open note can do from the keyboard, published by `NoteDetailView`.
struct OpenNoteActions {
    var isEditing: Bool
    var toggleEditing: (() -> Void)?
    var find: (() -> Void)?
    var exportMarkdown: (() -> Void)?
    var summarize: (() -> Void)?
}

extension FocusedValues {
    @Entry var mainWindowActions: MainWindowActions?
    @Entry var openNoteActions: OpenNoteActions?
}

/// Keyboard shortcuts for iPad with a keyboard and the Mac (where they also fill the menu bar).
/// Holding ⌘ on iPad lists them.
struct TrinoteCommands: Commands {
    @FocusedValue(\.mainWindowActions) private var window
    @FocusedValue(\.openNoteActions) private var note

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Note", comment: "Menu command")) { window?.newNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(window == nil)
        }

        CommandMenu(String(localized: "Go", comment: "Menu: navigation")) {
            Group {
                ForEach(Array(Self.shortcutFolders.enumerated()), id: \.element) { index, source in
                    Button(source.title) { window?.show(.list(source)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button(String(localized: "Search Notes", comment: "Menu command")) { window?.show(.search) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button(String(localized: "Settings", comment: "Main tab")) { window?.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                Button(String(localized: "Sync Now", comment: "Menu command")) { window?.syncNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(window == nil)
        }

        CommandMenu(String(localized: "Note", comment: "Menu: the open note")) {
            Button(note?.isEditing == true
                   ? String(localized: "Done Editing", comment: "Menu command")
                   : String(localized: "Edit Note", comment: "Menu command")) { note?.toggleEditing?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(note?.toggleEditing == nil)
            Button(String(localized: "Find in Note", comment: "Menu command")) { note?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(note?.find == nil)
            Divider()
            Button(String(localized: "Summarize", comment: "Note overflow: Apple Intelligence summary")) { note?.summarize?() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(note?.summarize == nil)
            Button(String(localized: "Export as Markdown…", comment: "Note overflow: save the note and its sub-notes as Markdown files")) { note?.exportMarkdown?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(note?.exportMarkdown == nil)
        }
    }

    /// ⌘1…⌘6 in the order the sidebar shows them.
    static let shortcutFolders: [NoteListSource] = [.allNotes, .inbox, .today, .todo, .favorites, .recents]
}
