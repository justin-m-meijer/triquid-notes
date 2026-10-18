import SwiftUI

/// Editor commands the native toolbar sends; raw values match `TN_FORMAT_COMMANDS` in editor.html.
enum EditorFormatCommand: String, CaseIterable {
    case bold, italic, underline, strike, code, superscript, `subscript`
    case paragraph, heading1, heading2, heading3, codeBlock
    case bulletList, orderedList, taskList, indent, outdent
    case alignLeft, alignCenter, alignRight, alignJustify, clearFormatting
    case blockquote, horizontalRule, insertTable, image, includeNote
    case insertTable2x2, insertTable4x4
    case addRowBefore, addRowAfter, deleteRow, addColumnBefore, addColumnAfter, deleteColumn
    case toggleHeaderRow, mergeOrSplitCells, deleteTable
    case undo, redo

    var javaScript: String {
        "try{window.editorBridge.exec('\(rawValue)')}catch(e){}"
    }
}

/// The floating glass format bar while editing (redesign screen 2): Aa, B, I | checklist, link, image | Done.
struct NoteFormatBar: View {
    let state: [String: Bool]
    let isSaving: Bool
    let onCommand: (EditorFormatCommand) -> Void
    let onShowPanel: () -> Void
    let onLinkToNote: () -> Void
    let onDone: () -> Void
    /// Apple Intelligence before Done (TestFlight feedback): it opens Summarize, Find To-dos and
    /// Suggest Title above the bar. Nil when Apple Intelligence can't read this note.
    var aiActions: ((NoteAIAction) -> Void)? = nil
    @Binding var isAIMenuOpen: Bool

    init(
        state: [String: Bool],
        isSaving: Bool,
        onCommand: @escaping (EditorFormatCommand) -> Void,
        onShowPanel: @escaping () -> Void,
        onLinkToNote: @escaping () -> Void,
        onDone: @escaping () -> Void,
        aiActions: ((NoteAIAction) -> Void)? = nil,
        isAIMenuOpen: Binding<Bool> = .constant(false)
    ) {
        self.state = state
        self.isSaving = isSaving
        self.onCommand = onCommand
        self.onShowPanel = onShowPanel
        self.onLinkToNote = onLinkToNote
        self.onDone = onDone
        self.aiActions = aiActions
        self._isAIMenuOpen = isAIMenuOpen
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isAIMenuOpen, let aiActions {
                NoteAIActionCapsules { action in
                    withAnimation(.bouncy) { isAIMenuOpen = false }
                    aiActions(action)
                }
                .padding(.trailing, 6)
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            barButton(label: String(localized: "Text style", comment: "Format bar: open the format panel"), isOn: false, action: onShowPanel) {
                Text(verbatim: "Aa").font(.system(size: 17, weight: .semibold))
            }
            barButton(label: String(localized: "Bold", comment: "Format bar"), isOn: state["bold"] == true, action: { onCommand(.bold) }) {
                Text(verbatim: "B").font(.system(size: 17, weight: .heavy))
            }
            barButton(label: String(localized: "Italic", comment: "Format bar"), isOn: state["italic"] == true, action: { onCommand(.italic) }) {
                Text(verbatim: "I").font(.system(size: 18, design: .serif)).italic()
            }
            Divider().frame(height: 22).padding(.horizontal, 2)
            barButton(label: String(localized: "Checklist", comment: "Format bar"), isOn: state["taskList"] == true, action: { onCommand(.taskList) }) {
                Image(systemName: "checklist")
            }
            barButton(label: String(localized: "Link to note", comment: "Format bar"), isOn: false, action: onLinkToNote) {
                Image(systemName: "link")
            }
            barButton(label: String(localized: "Insert image", comment: "Format bar"), isOn: false, action: { onCommand(.image) }) {
                Image(systemName: "photo")
            }
            if state["inTable"] == true {
                Menu {
                    TableEditMenu(onCommand: onCommand)
                } label: {
                    Image(systemName: "tablecells")
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.18), in: .circle)
                        .foregroundStyle(.tint)
                        .contentShape(.circle)
                }
                .accessibilityLabel(String(localized: "Table", comment: "Format panel insert"))
            }
            Spacer(minLength: 8)
            if aiActions != nil {
                barButton(label: String(localized: "Apple Intelligence", comment: "Note overflow: section header for on-device AI actions"), isOn: false, action: {
                    withAnimation(.bouncy) { isAIMenuOpen.toggle() }
                }) {
                    Image(systemName: "apple.intelligence").foregroundStyle(.tint)
                }
                .padding(.trailing, 4)
            }
            // A checkmark instead of the word Done: the word no longer fit next to Apple
            // Intelligence on an iPhone (TestFlight feedback).
            Button(action: onDone) {
                Group {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.trinoteOnAccent)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(isSaving)
            .accessibilityLabel(String(localized: "Done", comment: "Format bar: save and stop editing"))
        }
        .font(.system(size: 17))
        .foregroundStyle(Color.trinoteTextPrimary)
        .padding(.horizontal, 6)
        .frame(height: 54)
        .glassEffect(.regular, in: .capsule)
    }

    private func barButton(
        label: String,
        isOn: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 44, height: 44)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .circle)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteTextPrimary))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The Aa panel (redesign screen 2b): paragraph style, inline marks, lists, alignment and inserts,
/// reflecting the formatting at the cursor. Tools the panel does not cover stay one tap away in
/// the classic toolbar.
struct EditorFormatPanel: View {
    let state: [String: Bool]
    let onCommand: (EditorFormatCommand) -> Void
    let onShowAllTools: () -> Void

    private let styles: [(EditorFormatCommand, String, Font)] = [
        (.heading1, String(localized: "Title", comment: "Format panel: paragraph style"), .system(size: 20, weight: .bold)),
        (.heading2, String(localized: "Heading", comment: "Format panel: paragraph style"), .system(size: 17, weight: .bold)),
        (.heading3, String(localized: "Subheading", comment: "Format panel: paragraph style"), .system(size: 15, weight: .semibold)),
        (.paragraph, String(localized: "Body", comment: "Format panel: paragraph style"), .system(size: 15)),
        (.codeBlock, String(localized: "Mono", comment: "Format panel: paragraph style"), .system(size: 15, design: .monospaced)),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(styles, id: \.0) { command, title, font in
                            let isOn = state[command.rawValue] == true
                            Button { onCommand(command) } label: {
                                Text(title)
                                    .font(font)
                                    .padding(.horizontal, 14)
                                    .frame(height: 44)
                                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteTextPrimary))
                                    .background(isOn ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.trinoteCard), in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                }

                toggleRow([
                    (.bold, "bold", String(localized: "Bold", comment: "Format bar")),
                    (.italic, "italic", String(localized: "Italic", comment: "Format bar")),
                    (.underline, "underline", String(localized: "Underline", comment: "Format panel")),
                    (.strike, "strikethrough", String(localized: "Strikethrough", comment: "Format panel")),
                    (.code, "chevron.left.forwardslash.chevron.right", String(localized: "Inline code", comment: "Format panel")),
                    (.superscript, "textformat.superscript", String(localized: "Superscript", comment: "Format panel")),
                    (.`subscript`, "textformat.subscript", String(localized: "Subscript", comment: "Format panel")),
                ])
                toggleRow([
                    (.bulletList, "list.bullet", String(localized: "Bulleted list", comment: "Format panel")),
                    (.orderedList, "list.number", String(localized: "Numbered list", comment: "Format panel")),
                    (.taskList, "checklist", String(localized: "Checklist", comment: "Format bar")),
                    (.outdent, "decrease.indent", String(localized: "Outdent", comment: "Format panel")),
                    (.indent, "increase.indent", String(localized: "Indent", comment: "Format panel")),
                ])
                toggleRow([
                    (.alignLeft, "text.alignleft", String(localized: "Align left", comment: "Format panel")),
                    (.alignCenter, "text.aligncenter", String(localized: "Center", comment: "Format panel")),
                    (.alignRight, "text.alignright", String(localized: "Align right", comment: "Format panel")),
                    (.alignJustify, "text.justify", String(localized: "Justify", comment: "Format panel")),
                    (.clearFormatting, "eraser", String(localized: "Clear formatting", comment: "Format panel")),
                ])

                Text(String(localized: "Insert", comment: "Format panel section"))
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.trinoteTextSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    tableTile
                    insertTile(.codeBlock, "curlybraces", String(localized: "Code block", comment: "Format panel insert"))
                    insertTile(.blockquote, "text.quote", String(localized: "Quote", comment: "Format panel insert"))
                    insertTile(.horizontalRule, "minus", String(localized: "Divider", comment: "Format panel insert"))
                    insertTile(.includeNote, "doc.on.doc", String(localized: "Include note", comment: "Format panel insert"))
                    insertTile(.image, "photo", String(localized: "Image", comment: "Format panel insert"))
                }

                Button(action: onShowAllTools) {
                    Label(String(localized: "All tools (math, callouts, colors, tables…)", comment: "Format panel: show the classic editor toolbar"), systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .padding(20)
        }
        .background(Color.trinoteGround)
    }

    private func toggleRow(_ items: [(EditorFormatCommand, String, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { command, symbol, label in
                let isOn = state[command.rawValue] == true
                Button { onCommand(command) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteTextPrimary))
                        .background(isOn ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.trinoteCard), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    /// Table picks a size; with the cursor in a table it edits that table instead.
    private var tableTile: some View {
        Menu {
            if state["inTable"] == true {
                TableEditMenu(onCommand: onCommand)
            } else {
                Button(String(localized: "2 × 2", comment: "Format panel: table size")) { onCommand(.insertTable2x2) }
                Button(String(localized: "3 × 3 with header", comment: "Format panel: table size")) { onCommand(.insertTable) }
                Button(String(localized: "4 × 4 with header", comment: "Format panel: table size")) { onCommand(.insertTable4x4) }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "tablecells").font(.system(size: 20))
                Text(String(localized: "Table", comment: "Format panel insert")).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(state["inTable"] == true ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteTextPrimary))
            .background(Color.trinoteCard, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func insertTile(_ command: EditorFormatCommand, _ symbol: String, _ title: String) -> some View {
        Button { onCommand(command) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(Color.trinoteTextPrimary)
            .background(Color.trinoteCard, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Rows, columns, header and delete for the table at the cursor.
struct TableEditMenu: View {
    let onCommand: (EditorFormatCommand) -> Void

    var body: some View {
        Section(String(localized: "Rows", comment: "Table menu section")) {
            Button { onCommand(.addRowBefore) } label: { Label(String(localized: "Insert row above", comment: "Table menu"), systemImage: "arrow.up.to.line") }
            Button { onCommand(.addRowAfter) } label: { Label(String(localized: "Insert row below", comment: "Table menu"), systemImage: "arrow.down.to.line") }
            Button(role: .destructive) { onCommand(.deleteRow) } label: { Label(String(localized: "Delete row", comment: "Table menu"), systemImage: "minus.rectangle") }
        }
        Section(String(localized: "Columns", comment: "Table menu section")) {
            Button { onCommand(.addColumnBefore) } label: { Label(String(localized: "Insert column left", comment: "Table menu"), systemImage: "arrow.left.to.line") }
            Button { onCommand(.addColumnAfter) } label: { Label(String(localized: "Insert column right", comment: "Table menu"), systemImage: "arrow.right.to.line") }
            Button(role: .destructive) { onCommand(.deleteColumn) } label: { Label(String(localized: "Delete column", comment: "Table menu"), systemImage: "minus.rectangle.portrait") }
        }
        Section {
            Button { onCommand(.toggleHeaderRow) } label: { Label(String(localized: "Header row", comment: "Table menu"), systemImage: "tablecells.badge.ellipsis") }
            Button { onCommand(.mergeOrSplitCells) } label: { Label(String(localized: "Merge or split cells", comment: "Table menu"), systemImage: "square.split.2x1") }
        }
        Section {
            Button(role: .destructive) { onCommand(.deleteTable) } label: { Label(String(localized: "Delete table", comment: "Table menu"), systemImage: "trash") }
        }
    }
}
