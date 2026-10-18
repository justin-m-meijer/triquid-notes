import SwiftUI
import UIKit

extension Notification.Name {
    /// Scroll the visible note reader by a page. `object` is `TabletopPageDirection`.
    static let trinoteReaderPageRequest = Notification.Name("TrinoteReaderPageRequest")
}

enum TabletopPageDirection: Sendable {
    case up, down, top
}

/// The lower half of a partially folded iPhone Duo (tabletop posture). The note stays on the
/// upright half; this half rests on the table and holds controls, so a thumb never reaches across
/// the fold. Reading shows paging and note actions; editing shows the formatting commands.
struct TabletopDeck<Content: View>: View {
    /// Height of the lower segment, from the hinge down to the bottom safe area.
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // The fold band itself stays empty: nothing interactive on the crease.
            Capsule()
                .fill(Color.trinoteSeparator)
                .frame(width: 36, height: 4)
                .padding(.vertical, 10)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Reading controls on the lower half: page through the note without touching the upright screen.
struct TabletopReaderControls: View {
    @Environment(\.appFont) private var appFont
    let title: String
    let progress: CGFloat
    let canEdit: Bool
    let onFind: () -> Void
    let onEdit: () -> Void
    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue

    private var accent: AppAccent { AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline).fontDesign(appFont.displayDesign)
                    .foregroundStyle(Color.trinoteTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .contentTransition(.numericText())
            }
            ProgressView(value: min(max(progress, 0), 1))

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    deckButton(String(localized: "Previous page", comment: "Tabletop deck"), systemImage: "chevron.up", prominent: false) {
                        NotificationCenter.default.post(name: .trinoteReaderPageRequest, object: TabletopPageDirection.up)
                    }
                    deckButton(String(localized: "Next page", comment: "Tabletop deck"), systemImage: "chevron.down", prominent: true) {
                        NotificationCenter.default.post(name: .trinoteReaderPageRequest, object: TabletopPageDirection.down)
                    }
                }
            }

            HStack(spacing: 12) {
                smallButton(String(localized: "Top", comment: "Tabletop deck: scroll to the top"), systemImage: "arrow.up.to.line") {
                    NotificationCenter.default.post(name: .trinoteReaderPageRequest, object: TabletopPageDirection.top)
                }
                smallButton(String(localized: "Find", comment: "Tabletop deck: find on page"), systemImage: "magnifyingglass", action: onFind)
                if canEdit {
                    smallButton(String(localized: "Edit", comment: "Tabletop deck: start editing"), systemImage: "square.and.pencil", action: onEdit)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
    }

    private func deckButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(prominent ? AnyShapeStyle(.trinoteOnAccent) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .regular.tint(accent.color).interactive() : .regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}

/// Formatting on the lower half while editing: the whole command set as large targets, instead of
/// the compact bar that would otherwise sit on the crease.
struct TabletopFormatControls: View {
    let state: [String: Bool]
    let isSaving: Bool
    let onCommand: (EditorFormatCommand) -> Void
    let onShowPanel: () -> Void
    let onLinkToNote: () -> Void
    let onDone: () -> Void

    private struct Item: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let stateKey: String?
        let action: Action
        enum Action { case command(EditorFormatCommand), panel, link }
    }

    private var items: [Item] {
        [
            Item(id: "panel", title: String(localized: "Text style", comment: "Format bar: open the format panel"), systemImage: "textformat", stateKey: nil, action: .panel),
            Item(id: "bold", title: String(localized: "Bold", comment: "Format bar"), systemImage: "bold", stateKey: "bold", action: .command(.bold)),
            Item(id: "italic", title: String(localized: "Italic", comment: "Format bar"), systemImage: "italic", stateKey: "italic", action: .command(.italic)),
            Item(id: "underline", title: String(localized: "Underline", comment: "Format panel"), systemImage: "underline", stateKey: "underline", action: .command(.underline)),
            Item(id: "strike", title: String(localized: "Strikethrough", comment: "Format panel"), systemImage: "strikethrough", stateKey: "strike", action: .command(.strike)),
            Item(id: "h1", title: String(localized: "Heading", comment: "Format panel"), systemImage: "textformat.size.larger", stateKey: "heading1", action: .command(.heading1)),
            Item(id: "bullet", title: String(localized: "Bulleted list", comment: "Format panel"), systemImage: "list.bullet", stateKey: "bulletList", action: .command(.bulletList)),
            Item(id: "ordered", title: String(localized: "Numbered list", comment: "Format panel"), systemImage: "list.number", stateKey: "orderedList", action: .command(.orderedList)),
            Item(id: "task", title: String(localized: "Checklist", comment: "Format bar"), systemImage: "checklist", stateKey: "taskList", action: .command(.taskList)),
            Item(id: "quote", title: String(localized: "Quote", comment: "Format panel"), systemImage: "text.quote", stateKey: "blockquote", action: .command(.blockquote)),
            Item(id: "code", title: String(localized: "Code block", comment: "Format panel"), systemImage: "chevron.left.forwardslash.chevron.right", stateKey: "codeBlock", action: .command(.codeBlock)),
            Item(id: "link", title: String(localized: "Link to note", comment: "Format bar"), systemImage: "link", stateKey: nil, action: .link),
            Item(id: "image", title: String(localized: "Insert image", comment: "Format bar"), systemImage: "photo", stateKey: nil, action: .command(.image)),
            Item(id: "outdent", title: String(localized: "Outdent", comment: "Format panel"), systemImage: "decrease.indent", stateKey: nil, action: .command(.outdent)),
            Item(id: "indent", title: String(localized: "Indent", comment: "Format panel"), systemImage: "increase.indent", stateKey: nil, action: .command(.indent)),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 92), spacing: 10)], spacing: 10) {
                    ForEach(items) { item in
                        let isOn = item.stateKey.map { state[$0] == true } ?? false
                        Button {
                            switch item.action {
                            case .command(let command): onCommand(command)
                            case .panel: onShowPanel()
                            case .link: onLinkToNote()
                            }
                        } label: {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 20, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(isOn ? AnyShapeStyle(.trinoteOnAccent) : AnyShapeStyle(Color.trinoteTextPrimary))
                                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.trinoteCard), in: .rect(cornerRadius: 14))
                                .contentShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .animation(.snappy, value: isOn)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                Button { onCommand(.undo) } label: {
                    Label(String(localized: "Undo", comment: "Format panel"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button { onCommand(.redo) } label: {
                    Label(String(localized: "Redo", comment: "Format panel"), systemImage: "arrow.uturn.forward")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button(action: onDone) {
                    Group {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(String(localized: "Done", comment: "Dismiss sheet")).fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: 640)
    }
}
