import SwiftUI

/// The three on-device actions, with the labels and symbols the ••• menu uses.
enum NoteAIAction: CaseIterable, Identifiable {
    case summary, todos, title

    var id: Self { self }

    var kind: NoteSummaryModel.Kind {
        switch self {
        case .summary: .summary
        case .todos: .todos
        case .title: .title
        }
    }

    var title: String {
        switch self {
        case .summary: String(localized: "Summarize", comment: "Note overflow: Apple Intelligence summary")
        case .todos: String(localized: "Find To-dos", comment: "Note overflow: Apple Intelligence extracts action items")
        case .title: String(localized: "Suggest Title", comment: "Note overflow: Apple Intelligence title")
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.line.3.summary"
        case .todos: "checklist"
        case .title: "character.cursor.ibeam"
        }
    }
}

/// Summarize, Find To-dos and Suggest Title as glass capsules, right-aligned above the button
/// that opened them.
struct NoteAIActionCapsules: View {
    let onAction: (NoteAIAction) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(NoteAIAction.allCases) { action in
                    Button { onAction(action) } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.trinoteTextPrimary)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        }
    }
}
