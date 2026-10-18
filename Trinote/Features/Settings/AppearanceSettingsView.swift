import SwiftUI

/// Theme & accent (redesign screen 7, `Appearance` artboard): light/dark mode, the accent color
/// and a preview of the accent in both themes.
struct AppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.device.rawValue
    @AppStorage("colorTheme") private var colorTheme: String = ColorTheme.default.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccent: String = ""
    @AppStorage(AppFont.storageKey) private var appFont: String = AppFont.default.rawValue

    private var accent: AppAccent { AppAccent.resolve(stored: appAccent, legacyTheme: colorTheme) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(String(localized: "Theme", comment: "Appearance: light/dark section"))
                Picker(String(localized: "Theme", comment: "Appearance: light/dark section"), selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode == .device ? String(localized: "System", comment: "Appearance: follow system") : mode.localizedTitle)
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .padding(.horizontal, 16)

                sectionHeader(String(localized: "Accent color", comment: "Appearance: accent section"))
                    .padding(.top, 18)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppAccent.allCases) { option in
                        swatch(option)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 14)
                .background(Color.trinoteCard, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)

                Text(String(localized: "Each color has a light and a dark variant, so contrast holds in both themes.", comment: "Appearance: accent footer"))
                    .font(.footnote)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                sectionHeader(String(localized: "Font", comment: "Appearance: typeface section"))
                    .padding(.top, 18)
                VStack(spacing: 0) {
                    ForEach(Array(AppFont.allCases.enumerated()), id: \.element) { index, font in
                        if index > 0 {
                            Divider().padding(.leading, 72)
                        }
                        fontRow(font)
                    }
                }
                .background(Color.trinoteCard, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                Text(String(localized: "Used for headings, lists and the text of your notes.", comment: "Appearance: typeface footer"))
                    .font(.footnote)
                    .foregroundStyle(Color.trinoteTextSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                sectionHeader(String(localized: "Preview", comment: "Appearance: preview section"))
                    .padding(.top, 18)
                HStack(spacing: 10) {
                    preview(scheme: .light, label: String(localized: "Light", comment: "Appearance mode"))
                    preview(scheme: .dark, label: String(localized: "Dark", comment: "Appearance mode"))
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
        .background(Color.trinoteGround)
        .navigationTitle(String(localized: "Theme & accent", comment: "Appearance settings screen title"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.trinoteTextSecondary)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    /// One typeface: a sample in its heading design, its name and what it is like in its body design.
    private func fontRow(_ font: AppFont) -> some View {
        let isChosen = font.rawValue == appFont
        return Button {
            withAnimation(.snappy) { appFont = font.rawValue }
        } label: {
            HStack(spacing: 14) {
                Text(verbatim: "Aa")
                    .font(.system(size: 24, weight: .bold))
                    .fontDesign(font.displayDesign)
                    .foregroundStyle(isChosen ? accent.color : Color.trinoteTextPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.trinoteFill, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(font.localizedTitle)
                        .font(.body.weight(isChosen ? .semibold : .regular))
                        .fontDesign(font.bodyDesign)
                        .foregroundStyle(Color.trinoteTextPrimary)
                    Text(font.localizedSummary)
                        .font(.footnote)
                        .fontDesign(font.bodyDesign)
                        .foregroundStyle(Color.trinoteTextSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent.color)
                    .opacity(isChosen ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// A circle split diagonally into the accent's light and dark value, ringed when chosen.
    private func swatch(_ option: AppAccent) -> some View {
        let isChosen = option == accent
        return Button {
            appAccent = option.rawValue
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(light: option.lightHex, dark: option.lightHex), location: 0.5),
                            .init(color: Color(light: option.darkHex, dark: option.darkHex), location: 0.5),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .padding(6)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Circle().strokeBorder(isChosen ? option.color : .clear, lineWidth: 3)
                    }
                Text(option.localizedTitle)
                    .font(.system(size: 12, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Color.trinoteTextPrimary : Color.trinoteTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.localizedTitle)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The accent on a row, a label chip and a filled control, drawn in a fixed theme.
    private func preview(scheme: ColorScheme, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.trinoteTextSecondary)
            Text(verbatim: "Proxmox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent.color)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(accent.tint, in: .capsule)
            HStack(spacing: 6) {
                Text(verbatim: "#infra")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent.color)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(accent.tint, in: .capsule)
                Spacer(minLength: 0)
                Circle()
                    .fill(accent.color)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.trinoteCard, in: .rect(cornerRadius: 20))
        .environment(\.colorScheme, scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(label) preview", comment: "Appearance: accessibility label for a theme preview"))
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
}
