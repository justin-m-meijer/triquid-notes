import SwiftUI

/// The first screen a new person sees: the icon springs in and floats, the title and highlights
/// arrive one after another, then the two ways to start. Reduce Motion shows it all at once.
struct OnboardingView: View {
    let onConnect: () -> Void
    let onStartLocal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    private struct Highlight: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let detail: String
    }

    private let highlights: [Highlight] = [
        Highlight(
            id: 0,
            symbol: "apple.intelligence",
            title: String(localized: "Apple Intelligence, on your device", comment: "Onboarding highlight"),
            detail: String(localized: "Writing Tools, summaries, to-dos and titles, even from PDFs and photos. Made on your device.", comment: "Onboarding highlight detail")
        ),
        Highlight(
            id: 1,
            symbol: "square.and.arrow.down.on.square",
            title: String(localized: "Capture anything, fast", comment: "Onboarding highlight"),
            detail: String(localized: "Quick notes, scans with searchable text, or share a PDF from any app.", comment: "Onboarding highlight detail")
        ),
        Highlight(
            id: 2,
            symbol: "icloud.slash",
            title: String(localized: "Works offline", comment: "Onboarding highlight"),
            detail: String(localized: "Read and write anywhere; changes sync when you are back.", comment: "Onboarding highlight detail")
        ),
        Highlight(
            id: 3,
            symbol: "folder",
            title: String(localized: "Organized your way", comment: "Onboarding highlight"),
            detail: String(localized: "Drag notebooks into order or into a folder, with Trilium's colors and icons, favorites and to-dos.", comment: "Onboarding highlight detail")
        ),
        Highlight(
            id: 4,
            symbol: "magnifyingglass",
            title: String(localized: "Found in a moment", comment: "Onboarding highlight"),
            detail: String(localized: "Search every note, also from Spotlight.", comment: "Onboarding highlight detail")
        ),
        Highlight(
            id: 5,
            symbol: "paintpalette",
            title: String(localized: "Made to feel like yours", comment: "Onboarding highlight"),
            detail: String(localized: "Accent colors, fonts and dark mode, on iPhone, iPad and Mac in Liquid Glass.", comment: "Onboarding highlight detail")
        ),
    ]

    /// The step at which the buttons arrive, after the last highlight.
    private var buttonsStep: Int { 3 + highlights.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                icon
                    .scaleEffect(step >= 1 ? 1 : 0.4)
                    .opacity(step >= 1 ? 1 : 0)

                VStack(spacing: 8) {
                    Text(String(localized: "Welcome to Triquid Notes", comment: "Login welcome title"))
                        .font(.system(size: 32, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.trinoteTextPrimary)
                    Text(String(localized: "A calm place for everything you think, keep and plan.", comment: "Onboarding subtitle"))
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.trinoteTextSecondary)
                }
                .offset(y: step >= 2 ? 0 : 16)
                .opacity(step >= 2 ? 1 : 0)

                VStack(spacing: 12) {
                    ForEach(highlights) { item in
                        highlightRow(item)
                            .offset(y: step >= 3 + item.id ? 0 : 20)
                            .opacity(step >= 3 + item.id ? 1 : 0)
                    }
                }
                .padding(.vertical, 8)

                VStack(spacing: 12) {
                    Button(action: onConnect) {
                        Label(String(localized: "Connect to Trilium", comment: "Onboarding: sign in to a server"), systemImage: "server.rack")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.trinoteOnAccent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)

                    Button(action: onStartLocal) {
                        Label(String(localized: "Start without a server", comment: "Onboarding: local notebook"), systemImage: "iphone")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glass)

                    Text(String(localized: "Starting on this device? You can connect a Trilium server later; your notes come along.", comment: "Onboarding: local notebook hint"))
                        .font(.footnote)
                        .foregroundStyle(Color.trinoteTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .offset(y: step >= buttonsStep ? 0 : 24)
                .opacity(step >= buttonsStep ? 1 : 0)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(background.ignoresSafeArea())
        .task { await playEntrance() }
    }

    /// The app icon, drifting gently once it has arrived.
    private var icon: some View {
        Image("BootstrapAppIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 112, height: 112)
            .clipShape(.rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            .phaseAnimator([false, true], trigger: step >= buttonsStep) { content, lifted in
                content
                    .offset(y: lifted && !reduceMotion ? -6 : 0)
                    .rotationEffect(.degrees(lifted && !reduceMotion ? 2 : -2))
            } animation: { _ in
                .easeInOut(duration: 2.4)
            }
            .accessibilityHidden(true)
    }

    private func highlightRow(_ item: Highlight) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: step >= 3 + item.id)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.trinoteTextPrimary)
                Text(item.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.trinoteTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// A soft wash of the accent behind the ground color.
    private var background: some View {
        ZStack {
            Color.trinoteGround
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
        }
    }

    private func playEntrance() async {
        guard step == 0 else { return }
        if reduceMotion {
            step = buttonsStep
            return
        }
        for next in 1...buttonsStep {
            // The highlights follow each other quickly; six would otherwise keep the buttons waiting.
            try? await Task.sleep(for: .milliseconds(next == 1 ? 150 : (next >= 3 ? 110 : 180)))
            withAnimation(next == 1 ? .spring(response: 0.6, dampingFraction: 0.62) : .spring(response: 0.5, dampingFraction: 0.85)) {
                step = next
            }
        }
    }
}
