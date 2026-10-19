import SwiftUI
import UIKit

/// How a foldable is being held, from the hinge state and where the hinge lies in the window.
enum DevicePosture: String, Equatable, Sendable {
    /// No hinge (ordinary iPhone, iPad, Mac), the cover display, or the inner display opened flat.
    case flat
    /// Partially open with the hinge running horizontally: the lower half rests on a table and
    /// the upper half stands up like a laptop screen.
    case tabletop
    /// Partially open with the hinge running vertically, held like a book.
    case book
}

/// What the app knows about the hinge in the current window.
struct HingeGeometry: Equatable, Sendable {
    enum Status: Equatable, Sendable { case unknown, closed, partiallyOpen, fullyOpen }

    var status: Status = .unknown
    /// Opening angle in radians, when the system reports one.
    var angle: CGFloat?
    /// The hinge (fold band, with its margins) in window coordinates, when it crosses this window.
    var frameInWindow: CGRect?
    var windowSize: CGSize = .zero
    /// The window's bottom safe area (home indicator), so a bottom panel can stop above it.
    var windowSafeAreaBottom: CGFloat = 0
    /// The window's top safe area (status bar), so a bar drawn by hand can sit where the system's does.
    var windowSafeAreaTop: CGFloat = 0
    /// The wider of the window's side safe areas (a sensor along the side).
    var windowSafeAreaSide: CGFloat = 0

    /// A window with its status and sensor along one side and none on top: the Duo's cover display
    /// (466×678 pt) and its inner display held sideways (951×669). iOS then sets the bar's buttons
    /// down that side and leaves the bar itself as an empty band, which the content may cover.
    /// A phone held sideways (under 450 pt tall) keeps its bar on top and is left alone.
    var barsAtSide: Bool {
        min(windowSize.width, windowSize.height) >= 450 && windowSafeAreaTop < 1 && windowSafeAreaSide >= 60
    }

    var isHorizontal: Bool {
        guard let frame = frameInWindow else { return false }
        return frame.width > frame.height
    }

    var posture: DevicePosture {
        guard status == .partiallyOpen, let frame = frameInWindow, frame.width > 0 || frame.height > 0 else {
            return .flat
        }
        return isHorizontal ? .tabletop : .book
    }

    /// Height of the window below the hinge, above the bottom safe area: the "keyboard half" in tabletop.
    var lowerSegmentHeight: CGFloat {
        guard let frame = frameInWindow, isHorizontal else { return 0 }
        return max(0, windowSize.height - windowSafeAreaBottom - frame.maxY)
    }

    /// Width of the window up to the middle of a vertical hinge: a sidebar this wide puts its
    /// divider on the crease, with each page's content kept clear of the fold by its own margins.
    var leadingSegmentWidth: CGFloat? {
        guard let frame = frameInWindow, !isHorizontal, frame.minX > 0 else { return nil }
        return frame.midX
    }

    /// Where the hinge lies when the system reports no reserved region for it. The Duo's inner
    /// display is two halves of one sheet (669×951 pt, the cover display's aspect turned sideways),
    /// so the fold always halves the longer side. A window that is not the full inner display (Split
    /// View, the cover display) gets no hinge.
    static func fallbackHingeFrame(windowSize: CGSize, screenSize: CGSize, bandWidth: CGFloat = 24) -> CGRect? {
        let spansScreen = abs(windowSize.width - screenSize.width) < 1 && abs(windowSize.height - screenSize.height) < 1
        guard spansScreen, windowSize.width > 0, windowSize.height > 0 else { return nil }
        if windowSize.height >= windowSize.width {
            return CGRect(x: 0, y: windowSize.height / 2 - bandWidth / 2, width: windowSize.width, height: bandWidth)
        }
        return CGRect(x: windowSize.width / 2 - bandWidth / 2, y: 0, width: bandWidth, height: windowSize.height)
    }
}

/// Publishes `HingeGeometry` for the window it is installed in (see `HingeObserver`).
@MainActor
@Observable
final class PostureMonitor {
    private(set) var geometry = HingeGeometry()

    var posture: DevicePosture {
        #if DEBUG
        if let forced = Self.debugPosture { return forced }
        #endif
        return geometry.posture
    }

    /// Height for a panel under the hinge in tabletop posture.
    var lowerSegmentHeight: CGFloat {
        #if DEBUG
        if Self.debugPosture == .tabletop, geometry.lowerSegmentHeight == 0 {
            // Simulated: the lower half of whatever window this is.
            return max(0, geometry.windowSize.height / 2 - 12 - geometry.windowSafeAreaBottom)
        }
        #endif
        return geometry.lowerSegmentHeight
    }

    /// Sidebar width that ends at a vertical hinge (unfolded inner display held landscape, flat or
    /// as a book), so the tree and the note each get one page and nothing sits on the crease.
    var sidebarWidthAtHinge: CGFloat? {
        #if DEBUG
        if Self.debugPosture == .book, geometry.leadingSegmentWidth == nil, geometry.windowSize.width > 0 {
            return geometry.windowSize.width / 2
        }
        #endif
        guard let width = geometry.leadingSegmentWidth, width >= 260 else { return nil }
        return width
    }

    func update(_ geometry: HingeGeometry) {
        guard geometry != self.geometry else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            self.geometry = geometry
        }
    }

    #if DEBUG
    /// `-TrinoteDebugPosture tabletop|book`: lay out as if partially folded, for simulators that cannot fold.
    static let debugPosture: DevicePosture? = UserDefaults.standard.string(forKey: "TrinoteDebugPosture").flatMap(DevicePosture.init(rawValue:))
    #endif
}

extension EnvironmentValues {
    @Entry var postureMonitor: PostureMonitor? = nil
}

/// An invisible full-window view that watches the hinge (`UIHingeInteraction`) and its position
/// (`reservedRegions(kind: .division)`, iOS 27.1) and reports both to a `PostureMonitor`.
struct HingeObserver: UIViewRepresentable {
    let monitor: PostureMonitor

    func makeUIView(context: Context) -> HingeObserverView {
        let view = HingeObserverView()
        view.monitor = monitor
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HingeObserverView, context: Context) {
        uiView.monitor = monitor
    }
}

final class HingeObserverView: UIView {
    weak var monitor: PostureMonitor?
    private var status: HingeGeometry.Status = .unknown
    private var angle: CGFloat?
    private var hingeInteraction: (any UIInteraction)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installHingeInteractionIfNeeded()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        report()
    }

    private func installHingeInteractionIfNeeded() {
        guard hingeInteraction == nil else { return }
        // A Mac has no hinge, and Mac Catalyst has no hinge API: the posture stays unknown, as on iPad.
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                if let hinge = update.hinge {
                    self.status = switch hinge.status {
                    case .closed: .closed
                    case .partiallyOpen: .partiallyOpen
                    case .fullyOpen: .fullyOpen
                    default: .unknown
                    }
                    self.angle = hinge.angle
                } else {
                    // Left a hierarchy with hinge updates (another display, no hinge at all).
                    self.status = .unknown
                    self.angle = nil
                }
                self.report()
            }
            addInteraction(interaction)
            hingeInteraction = interaction
        }
        #endif
    }

    private func report() {
        guard let window, let monitor else { return }
        var geometry = HingeGeometry()
        geometry.status = status
        geometry.angle = angle
        geometry.windowSize = window.bounds.size
        geometry.windowSafeAreaBottom = window.safeAreaInsets.bottom
        geometry.windowSafeAreaTop = window.safeAreaInsets.top
        geometry.windowSafeAreaSide = max(window.safeAreaInsets.left, window.safeAreaInsets.right)
        if status != .unknown {
            geometry.frameInWindow = divisionRegionInWindow(window) ?? HingeGeometry.fallbackHingeFrame(
                windowSize: window.bounds.size,
                screenSize: window.windowScene?.screen.bounds.size ?? .zero
            )
        }
        monitor.update(geometry)
    }

    private func divisionRegionInWindow(_ window: UIWindow) -> CGRect? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard #available(iOS 27.1, *) else { return nil }
        let regions = window.reservedRegions(kind: .division).filter(\.isActive)
        return regions.first?.frame
        #endif
    }
}

/// Sizes a split view's sidebar column to the page before the hinge, when there is one.
struct HingeAlignedSidebarWidth: ViewModifier {
    @Environment(\.postureMonitor) private var postureMonitor

    func body(content: Content) -> some View {
        if let width = postureMonitor?.sidebarWidthAtHinge {
            content.navigationSplitViewColumnWidth(min: 260, ideal: width, max: width)
        } else {
            content
        }
    }
}

extension View {
    func hingeAlignedSidebarWidth() -> some View {
        modifier(HingeAlignedSidebarWidth())
    }
}

/// Moves a floating button at the bottom trailing corner into the side strip where iOS puts the
/// bar's buttons (the Duo's cover display, its inner display held sideways), so it no longer
/// covers text (TestFlight feedback). Elsewhere it stays where it is.
struct SideStripPlacement: ViewModifier {
    /// The button's trailing padding and width where it normally sits.
    let trailingPadding: CGFloat
    let width: CGFloat
    @Environment(\.postureMonitor) private var postureMonitor

    func body(content: Content) -> some View {
        let geometry = postureMonitor?.geometry
        let offset = geometry?.barsAtSide == true ? (geometry?.windowSafeAreaSide ?? 0) / 2 + trailingPadding + width / 2 : 0
        content.offset(x: offset)
    }
}

extension View {
    func intoSideStrip(trailingPadding: CGFloat, width: CGFloat) -> some View {
        modifier(SideStripPlacement(trailingPadding: trailingPadding, width: width))
    }
}
